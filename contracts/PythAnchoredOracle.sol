// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {AggregatorV3Interface} from '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {PythLazerLib} from './vendor/pyth-lazer/PythLazerLib.sol';
import {PythLazerStructs} from './vendor/pyth-lazer/PythLazerStructs.sol';

/**
 * @title PythAnchoredOracle
 * @author MNX Markets <help@mnx.fi>
 * @notice AggregatorV3-compatible oracle whose price is cryptographically
 *   anchored to Pyth Lazer. One instance per market, like the other price oracles.
 *
 * Two write paths, both permissioned to `updaters`:
 *
 *  1. submitPythPrice(update) — LIVE. The backend forwards a Pyth Lazer EVM
 *     signed update. The contract verifies Pyth's secp256k1/ECDSA signature
 *     in-oracle, parses the signed payload with Pyth's own audited parser
 *     (vendored under contracts/vendor/pyth-lazer), pins the feed id + exponent,
 *     and — when the signed MarketSession is not Closed — steps the answer
 *     toward the derived price, moving at most maxUpdateBps per write (the
 *     same stepping the off-chain updater computes; see _boundToMaxUpdate). The
 *     signed payload fixes the TARGET, so a compromised updater can only walk
 *     the price toward a real, fresh Pyth print; the cap bounds how far any
 *     single write can move consumers, and every accepted write must carry a
 *     strictly newer signed payload timestamp than the last (replaying an
 *     already-consumed payload reverts). The signed timestamp must also sit
 *     inside a two-sided freshness window: at most maxAgeSeconds old and at
 *     most MAX_FUTURE_DRIFT_SECONDS ahead of the chain clock (a far-future
 *     stamp would otherwise wedge the strictly-newer rule). A legitimate large gap
 *     (overnight/weekend move) converges over successive updates instead of
 *     jumping in one write.
 *
 *  2. submitSecondaryPrice(pythClosedProof, hlPrice) — CLOSED. When Pyth reports
 *     the equity session is Closed there is no live primary price, so a bounded
 *     Hyperliquid (HL) secondary bridges the gap. The caller supplies a FRESH
 *     signed Pyth update proving MarketSession == Closed; the contract derives
 *     the frozen close print as the anchor and requires the (unsigned) HL price
 *     to sit within ±secondaryBandBps of it. The banded HL target then steps
 *     under the same maxUpdateBps rule as the live path.
 *
 * HKD equities: Pyth prices the equity in HKD, so the backend batches the equity
 * feed and the USD/HKD FX feed (1510) into ONE signed update. `usd = hkd / fxRate`.
 */
contract PythAnchoredOracle is AggregatorV3Interface, Ownable2Step {
  // immutable metadata
  uint8 private constant DECIMALS = 18;
  uint256 public constant override version = 1;

  // Outer Pyth Lazer EVM envelope magic (uint32(bytes4("*\"\x99\x9a"))).
  uint32 private constant EVM_FORMAT_MAGIC = 706910618;
  // HKD-peg sanity band, matching the off-chain updater: 7.5..8.0 HKD per USD,
  // stored ×10 so the bound stays integer.
  // HKD-specific; if a non-HKD FX market is ever added, promote to config.
  uint256 private constant FX_PEG_MIN_X10 = 75;
  uint256 private constant FX_PEG_MAX_X10 = 80;

  // updater role
  mapping(address => bool) public updaters;

  // owner-adjustable limits; the owner can only tighten them (see _setConfig).
  // maxStalenessSeconds is advisory: Perpetual does not read it and enforces
  // its own oracleMaxStalenessSeconds against updatedAt instead.
  uint128 public maxStalenessSeconds; // advisory; 0 = none
  uint128 public maxUpdateBps; // required nonzero at deploy; can only decrease (tightening-only)

  // round storage
  uint80 private _latestRound;
  uint256 public lastUpdateBlock;
  mapping(uint80 => int256) private _answers; // 18-dec scaled
  mapping(uint80 => uint256) private _startedAt;
  mapping(uint80 => uint256) private _updatedAt;

  uint128 public minUpdateIntervalSeconds; // 0 disables

  // --- Pyth Lazer anchoring config ---
  // The acceptance root: signatures must recover to this signer while
  // unexpired. IMMUTABLE by design — fleet-wide probes (2026-08-04) showed
  // Pyth registers ONE Lazer signer per chain with a ~2034 expiry and has
  // never rotated it, so a signer change is a new oracle deploy + market
  // repoint, not a governance action. (An earlier registry-anchored rotation
  // mode was removed on that evidence.)
  address public immutable trustedSigner; // Pyth Lazer signer (Douro Labs / Pyth DAO)
  uint256 public immutable signerExpiresAt; // accepted only while block.timestamp < this

  uint32 public lazerFeedId; // equity feed id
  int16 public exponent; // pinned equity exponent (payload must match)
  uint32 public fxFeedId; // 0 = USD-denominated (no FX combine); else USD/HKD feed id
  int16 public fxExponent; // pinned FX exponent (must be <= 0)
  uint64 public maxAgeSeconds; // payload-timestamp freshness / anti-replay window (stale side)
  uint32 public secondaryBandBps; // HL secondary band vs the Pyth closed anchor

  // Future side of the freshness window: allowance for the Lazer stamping
  // clock running slightly ahead of block.timestamp. A payload dated further
  // ahead is rejected — beyond hygiene, an accepted far-future timestamp would
  // advance lastPayloadTimestamp past real time and wedge every later update
  // until the chain clock catches up to it.
  uint64 public constant MAX_FUTURE_DRIFT_SECONDS = 60;
  // Signed payload timestamp (seconds) of the last ACCEPTED write, strictly
  // increasing. Complements maxAgeSeconds: the age window bounds how old a
  // payload may be when first accepted; monotonicity stops a compromised
  // updater from re-serving any already-consumed payload inside that window
  // (e.g. walking the answer back and forth between two cached prints).
  uint64 public lastPayloadTimestamp;
  // Per-feed SIGNED observation freshness on active sessions. Required
  // nonzero at initialization and on every reconfig — a security invariant
  // must not depend on a deploy checklist or be quietly disabled later. The
  // envelope timestamp dates the attestation; each feed's FeedUpdateTimestamp
  // dates the observation, and Lazer serves carried-forward observations with
  // a fresh envelope during thin sessions. The backend rejects those
  // off-chain; this closes the same gap against an updater that bypasses the
  // backend. Closed sessions are exempt — the frozen close print is
  // legitimately old and is certified by the fresh envelope + signed Closed
  // session instead. Set generously (hours) to avoid false freezes on thin
  // preMarket/overNight publishing; the off-chain gate stays the tight one.
  // Spread (bestBid/bestAsk) is deliberately NOT enforced on-chain: it is an
  // off-chain quality filter, and a wide-spread print is still a real signed
  // Pyth price bounded by stepping.
  uint64 public feedMaxAgeSeconds;

  // Deploy-time reviewed trust envelope. Governance is deliberately WEAK: the
  // owner key may rotate updaters and move the limits below within
  // [safer, initial] — its main powers are throttle and freeze. One bounded
  // residual remains: an owner can self-grant updater and,
  // during a Pyth-attested Closed session, steer the answer within
  // ±secondaryBandBps of the SIGNED close under maxUpdateBps stepping. It can
  // never fabricate an arbitrary price during live sessions: live targets
  // come only from signed payloads. The trusted signer (address AND expiry)
  // and the feed identity (ids + exponents) are immutable after deploy;
  // changing any of them is a NEW oracle deploy + market repoint. Deploy this
  // contract non-upgradeable, or an upgrade admin re-opens everything this
  // closes.
  uint128 public initialMinUpdateIntervalSeconds;
  uint64 public initialMaxAgeSeconds;
  uint32 public initialSecondaryBandBps;
  uint64 public initialFeedMaxAgeSeconds;

  event UpdaterSet(address account, bool isAuthorized);
  event UpdaterRotated(address retiredUpdater, address newUpdater);
  event ConfigSet(
    uint128 maxStalenessSeconds,
    uint128 maxUpdateBps,
    uint128 minUpdateIntervalSeconds
  );
  event PriceUpdated(uint80 roundId, int256 answer, uint256 timestamp);
  event LazerConfigSet(
    uint32 lazerFeedId,
    int16 exponent,
    uint32 fxFeedId,
    int16 fxExponent,
    uint64 maxAgeSeconds,
    uint32 secondaryBandBps
  );
  event TrustedSignerSet(address signer, uint256 expiresAt);
  event LazerLimitsSet(
    uint64 maxAgeSeconds,
    uint32 secondaryBandBps,
    uint64 feedMaxAgeSeconds
  );
  // `answer` is the written (possibly maxUpdateBps-stepped) value; the second
  // field is the raw target it stepped toward (signed Pyth price / HL print).
  event PythPriceSubmitted(
    uint80 roundId,
    int256 answer,
    int256 pythPriceE18,
    uint8 session,
    uint64 payloadTimestamp
  );
  event SecondaryPriceSubmitted(
    uint80 roundId,
    int256 answer,
    int256 hlPrice,
    uint256 anchorE18,
    uint64 payloadTimestamp
  );

  struct LazerConfig {
    uint32 lazerFeedId;
    int16 exponent;
    uint32 fxFeedId;
    int16 fxExponent;
    uint64 maxAgeSeconds;
    uint32 secondaryBandBps;
    uint64 feedMaxAgeSeconds;
  }

  /**
   * @dev NOT upgradeable, deliberately: this contract's governance guarantees
   * (immutable signer/feeds, enveloped knobs) are only as strong as the
   * absence of an upgrade admin. Deploy directly — never behind a proxy.
   * @param initialOwner Address that receives the owner role. Deliberately not
   * derived from the deploying key (mirrors ImmutableBackendPriceOracle): a deployment
   * key that is later retired must not inherit any live authority from having
   * run the deployment.
   * @param initialUpdater The only address authorized to submit updates at
   * deployment. It is an independent role; the owner does NOT become an
   * updater here.
   */
  constructor(
    address initialOwner,
    address initialUpdater,
    int256 initialAnswer,
    uint128 _maxStalenessSeconds,
    uint128 _maxUpdateBps,
    uint128 _minUpdateIntervalSeconds,
    address _trustedSigner,
    uint256 _signerExpiresAt,
    LazerConfig memory cfg
  ) Ownable(initialOwner) {
    _validateAnswer(initialAnswer);
    // The stepping cap is an invariant, not a deploy-checklist item: cap 0
    // would let a compromised updater walk the answer arbitrarily during a
    // Closed session (band-checked only against the proof's close). Same
    // argument as the required-nonzero feedMaxAgeSeconds one field over.
    require(_maxUpdateBps > 0, 'PAO: maxUpdateBps=0');
    _setConfig(_maxStalenessSeconds, _maxUpdateBps, _minUpdateIntervalSeconds);
    _setLazerConfig(cfg);
    require(_trustedSigner != address(0), 'PAO: signer=0');
    // A deploy whose signer expiry is already past could never accept an
    // update — same constructor-enforced-invariant argument as the cap above.
    require(
      _signerExpiresAt > block.timestamp,
      'PAO: signer expiry not in future'
    );
    trustedSigner = _trustedSigner;
    signerExpiresAt = _signerExpiresAt;
    emit TrustedSignerSet(_trustedSigner, _signerExpiresAt);
    _setUpdater(initialUpdater, true);
    // Record the reviewed trust envelope; owner moves stay inside it.
    initialMinUpdateIntervalSeconds = _minUpdateIntervalSeconds;
    initialMaxAgeSeconds = cfg.maxAgeSeconds;
    initialSecondaryBandBps = cfg.secondaryBandBps;
    initialFeedMaxAgeSeconds = cfg.feedMaxAgeSeconds;
    // The constructor seed is written as round 1 unstepped, as in
    // ImmutableBackendPriceOracle. On-chain it is only range-checked
    // (_validateAnswer above: 0 < seed <= type(uint128).max); its closeness to
    // the market is validated by the off-chain deploy preflight, which
    // certifies it within 20% of a fresh SIGNED Pyth print — live or
    // Closed-proof. The only re-seed path is redeploy + repoint.
    _writeNewRound(initialAnswer);
  }

  // ---------------------------------------------------------------------------
  // Admin
  // ---------------------------------------------------------------------------
  function setUpdater(address account, bool isAuthorized) external onlyOwner {
    _setUpdater(account, isAuthorized);
  }

  /// @notice Atomically retire one updater and authorize its replacement, so a
  ///   handoff can never leave the retired key authorized or the oracle
  ///   without a publisher (mirrors ImmutableBackendPriceOracle.rotateUpdater).
  function rotateUpdater(
    address retiredUpdater,
    address newUpdater
  ) external onlyOwner {
    require(updaters[retiredUpdater], 'PAO: retired not updater');
    require(retiredUpdater != newUpdater, 'PAO: rotation to same updater');
    _setUpdater(retiredUpdater, false);
    _setUpdater(newUpdater, true);
    emit UpdaterRotated(retiredUpdater, newUpdater);
  }

  /// @notice Disabled. This oracle must always have an owner: `updaters` is
  ///   not enumerable, so a stray authorized key at renunciation could never
  ///   be revoked again, and the config and limit setters would freeze
  ///   forever (the trusted signer is immutable either way).
  ///   Ownership still moves through transferOwnership / acceptOwnership.
  function renounceOwnership() public pure override {
    revert('PAO: ownership cannot be renounced');
  }

  function _setUpdater(address account, bool isAuthorized) private {
    require(account != address(0), 'PAO: updater is zero');
    updaters[account] = isAuthorized;
    emit UpdaterSet(account, isAuthorized);
  }

  function setConfig(
    uint128 _maxStalenessSeconds,
    uint128 _maxUpdateBps,
    uint128 _minUpdateIntervalSeconds
  ) external onlyOwner {
    _setConfig(_maxStalenessSeconds, _maxUpdateBps, _minUpdateIntervalSeconds);
  }

  function _setConfig(
    uint128 _maxStalenessSeconds,
    uint128 _maxUpdateBps,
    uint128 _minUpdateIntervalSeconds
  ) private {
    // maxUpdateBps is tightening-only once positive: widening requires a
    // replacement oracle + consumer opt-in.
    if (maxUpdateBps > 0) {
      require(_maxUpdateBps > 0, 'PAO: cap cannot be disabled');
      require(_maxUpdateBps <= maxUpdateBps, 'PAO: cap cannot increase');
    }
    // maxStalenessSeconds is advisory: Perpetual does not read it and enforces
    // its own oracleMaxStalenessSeconds against updatedAt. It still ratchets:
    // once positive, no disable, no increase.
    if (maxStalenessSeconds > 0) {
      require(_maxStalenessSeconds > 0, 'PAO: staleness cannot be disabled');
      require(
        _maxStalenessSeconds <= maxStalenessSeconds,
        'PAO: staleness cannot increase'
      );
    }
    // A lower min interval means faster stepping — cap x frequency is the
    // drift rate a compromised key gets — so the deploy-time value is a floor.
    require(
      _minUpdateIntervalSeconds >= initialMinUpdateIntervalSeconds,
      'PAO: interval below envelope'
    );
    maxStalenessSeconds = _maxStalenessSeconds;
    maxUpdateBps = _maxUpdateBps;
    minUpdateIntervalSeconds = _minUpdateIntervalSeconds;
    emit ConfigSet(_maxStalenessSeconds, _maxUpdateBps, _minUpdateIntervalSeconds);
  }

  /// @notice Owner-adjustable freshness and band limits, each bounded by its
  ///   deploy-time reviewed value: the trust envelope can shrink and recover,
  ///   never grow. Feed identity (ids + exponents) has no setter at all.
  function setLazerLimits(
    uint64 _maxAgeSeconds,
    uint32 _secondaryBandBps,
    uint64 _feedMaxAgeSeconds
  ) external onlyOwner {
    require(
      _maxAgeSeconds > 0 && _maxAgeSeconds <= initialMaxAgeSeconds,
      'PAO: maxAge outside envelope'
    );
    require(
      _secondaryBandBps > 0 && _secondaryBandBps <= initialSecondaryBandBps,
      'PAO: band outside envelope'
    );
    require(
      _feedMaxAgeSeconds > 0 &&
        _feedMaxAgeSeconds <= initialFeedMaxAgeSeconds,
      'PAO: feedMaxAge outside envelope'
    );
    maxAgeSeconds = _maxAgeSeconds;
    secondaryBandBps = _secondaryBandBps;
    feedMaxAgeSeconds = _feedMaxAgeSeconds;
    emit LazerLimitsSet(_maxAgeSeconds, _secondaryBandBps, _feedMaxAgeSeconds);
  }

  function _setLazerConfig(LazerConfig memory cfg) private {
    require(cfg.lazerFeedId != 0, 'PAO: feedId=0');
    require(cfg.maxAgeSeconds > 0, 'PAO: maxAge=0');
    require(cfg.feedMaxAgeSeconds > 0, 'PAO: feedMaxAge=0');
    require(
      cfg.secondaryBandBps > 0 && cfg.secondaryBandBps <= 10000,
      'PAO: bad band'
    );
    // Exponents below -18 truncate the derived price toward zero, and far
    // enough below, 10 ** -e overflows and reverts every update forever —
    // feeds have no setters, so the only remedy would be redeploy + repoint.
    // Real Lazer feeds use roughly -5..-8; within [-18, 0] the
    // derivation is exact: e = 18 + exponent stays in [0, 18], so
    // 10^e <= 1e18 and an int64 mantissa can never overflow the uint128
    // answer bound. Positive exponents are rejected outright (a price
    // multiplied by 10^(18+exp) > 1e18 has no legitimate feed shape).
    require(
      cfg.exponent <= 0 && cfg.exponent >= -18,
      'PAO: exponent out of range'
    );
    if (cfg.fxFeedId != 0) {
      // fxExponent must be <= 0 so the peg scale 10^(-fxExponent) is an integer.
      require(cfg.fxExponent <= 0, 'PAO: fxExp must be <= 0');
      // Same exactness window for the FX scale 10^(-fxExponent) <= 1e18.
      require(cfg.fxExponent >= -18, 'PAO: fxExp out of range');
      require(cfg.fxFeedId != cfg.lazerFeedId, 'PAO: fx == equity');
    }
    lazerFeedId = cfg.lazerFeedId;
    exponent = cfg.exponent;
    fxFeedId = cfg.fxFeedId;
    fxExponent = cfg.fxExponent;
    maxAgeSeconds = cfg.maxAgeSeconds;
    secondaryBandBps = cfg.secondaryBandBps;
    feedMaxAgeSeconds = cfg.feedMaxAgeSeconds;
    emit LazerConfigSet(
      cfg.lazerFeedId,
      cfg.exponent,
      cfg.fxFeedId,
      cfg.fxExponent,
      cfg.maxAgeSeconds,
      cfg.secondaryBandBps
    );
  }

  // ---------------------------------------------------------------------------
  // Updater entry points
  // ---------------------------------------------------------------------------

  /// @notice LIVE path: write the price from a Pyth-signed update (session != Closed).
  function submitPythPrice(bytes calldata update) external {
    require(updaters[_msgSender()], 'PAO: not updater');
    (
      uint256 priceE18,
      PythLazerStructs.MarketSession session,
      uint64 payloadTsSec
    ) = _verifyAndDerive(update);
    require(
      session != PythLazerStructs.MarketSession.Closed,
      'PAO: market closed'
    );
    require(
      block.timestamp <= uint256(payloadTsSec) + maxAgeSeconds,
      'PAO: stale payload'
    );
    _requireNotFutureDated(payloadTsSec);
    _requireNewerPayload(payloadTsSec);
    int256 target = _priceE18ToAnswer(priceE18);
    // The signed payload fixes the target; the write steps toward it under
    // maxUpdateBps (see contract docs). One-write-per-block + min-interval
    // still apply via _writeNewRound.
    int256 answer = _boundToMaxUpdate(target);
    _writeNewRound(answer);
    emit PythPriceSubmitted(
      _latestRound,
      answer,
      target,
      uint8(session),
      payloadTsSec
    );
  }

  /// @notice CLOSED path: write a bounded HL secondary while Pyth proves the
  ///   session is Closed. `pythClosedProof` is a FRESH Pyth-signed update.
  function submitSecondaryPrice(
    bytes calldata pythClosedProof,
    int256 hlPrice
  ) external {
    require(updaters[_msgSender()], 'PAO: not updater');
    (
      uint256 anchorE18,
      PythLazerStructs.MarketSession session,
      uint64 payloadTsSec
    ) = _verifyAndDerive(pythClosedProof);
    // Only bridge to the unsigned HL secondary while Pyth itself attests Closed,
    // and only from a fresh proof (a stale/replayed closed proof is rejected here).
    require(
      session == PythLazerStructs.MarketSession.Closed,
      'PAO: session not closed'
    );
    require(
      block.timestamp <= uint256(payloadTsSec) + maxAgeSeconds,
      'PAO: stale proof'
    );
    _requireNotFutureDated(payloadTsSec);
    _requireNewerPayload(payloadTsSec);
    _validateAnswer(hlPrice);
    // Bound HL to ±secondaryBandBps of the freshly-proven Pyth close (frozen
    // last-session print). Mirrors the off-chain updater's band.
    uint256 hl = uint256(hlPrice);
    uint256 diff = hl > anchorE18 ? hl - anchorE18 : anchorE18 - hl;
    require(
      diff * 10000 <= anchorE18 * uint256(secondaryBandBps),
      'PAO: secondary out of band'
    );
    // The band legitimizes the HL target; the write then steps toward it under
    // maxUpdateBps like the live path (HL is not cryptographically verified,
    // but the anchor band above already bounds the target itself).
    int256 answer = _boundToMaxUpdate(hlPrice);
    _writeNewRound(answer);
    emit SecondaryPriceSubmitted(
      _latestRound,
      answer,
      hlPrice,
      anchorE18,
      payloadTsSec
    );
  }

  // ---------------------------------------------------------------------------
  // Verification + derivation
  // ---------------------------------------------------------------------------

  /// @dev Verify the Pyth Lazer EVM envelope in-oracle (no fee) and return the
  ///   signed payload. Envelope: magic(4) | r(32) s(32) v(1) | payload_len(2 BE) | payload.
  function _verifyLazerUpdate(
    bytes calldata update
  ) internal view returns (bytes memory payload) {
    require(update.length >= 71, 'PAO: update too short');
    require(
      uint32(bytes4(update[0:4])) == EVM_FORMAT_MAGIC,
      'PAO: bad evm magic'
    );
    uint16 payloadLen = uint16(bytes2(update[69:71]));
    require(update.length >= 71 + uint256(payloadLen), 'PAO: truncated payload');
    bytes calldata payloadCd = update[71:71 + payloadLen];
    (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
      keccak256(payloadCd),
      uint8(update[68]) + 27,
      bytes32(update[4:36]),
      bytes32(update[36:68])
    );
    require(err == ECDSA.RecoverError.NoError, 'PAO: sig recover failed');
    require(signer != address(0), 'PAO: zero signer');
    require(signer == trustedSigner, 'PAO: untrusted signer');
    require(block.timestamp < signerExpiresAt, 'PAO: signer expired');
    payload = payloadCd; // copy calldata slice to memory for the parser
  }

  /// @dev Verify, parse, pin feed id/exponent, and derive the USD e18 price.
  ///   Returns the equity's signed MarketSession and the payload-level timestamp
  ///   (seconds). The payload timestamp advances on every Pyth publish (anti-replay).
  function _verifyAndDerive(
    bytes calldata update
  )
    internal
    view
    returns (
      uint256 priceE18,
      PythLazerStructs.MarketSession session,
      uint64 payloadTsSec
    )
  {
    bytes memory payload = _verifyLazerUpdate(update);
    PythLazerStructs.Update memory parsed = PythLazerLib.parseUpdateFromPayload(
      payload
    );
    require(parsed.feeds.length >= 1, 'PAO: no feeds');
    payloadTsSec = uint64(parsed.timestamp / 1_000_000); // µs -> s

    // Feeds are matched by their SIGNED id, never by position: identity is
    // pinned in config, so a request-order change by Lazer or the backend
    // must not freeze the oracle.
    PythLazerStructs.Feed memory eq = _findFeedById(
      parsed.feeds,
      lazerFeedId,
      'PAO: wrong feed id'
    );
    require(PythLazerLib.getExponent(eq) == exponent, 'PAO: wrong exponent');
    session = PythLazerLib.getMarketSession(eq);
    // Per-feed signed observation freshness (see feedMaxAgeSeconds; always
    // configured nonzero). Only on active sessions: a Closed payload's frozen
    // print is legitimately old.
    bool enforceFeedFreshness =
      session != PythLazerStructs.MarketSession.Closed;
    if (enforceFeedFreshness) {
      _requireFreshFeedObservation(eq);
    }
    int64 eqMantissa = PythLazerLib.getPrice(eq);
    require(eqMantissa > 0, 'PAO: non-positive price');
    priceE18 = _mantissaToE18(eqMantissa, exponent);

    if (fxFeedId != 0) {
      require(parsed.feeds.length >= 2, 'PAO: missing fx feed');
      PythLazerStructs.Feed memory fx = _findFeedById(
        parsed.feeds,
        fxFeedId,
        'PAO: wrong fx feed id'
      );
      require(
        PythLazerLib.getExponent(fx) == fxExponent,
        'PAO: wrong fx exponent'
      );
      // The FX feed's freshness follows ITS OWN signed session, not the
      // equity's: USD/HKD trades near-continuously, so during
      // an equity Closed session the FX observation is normally live and must
      // still be fresh — only an FX feed that is ITSELF Closed carries a
      // legitimately frozen print. A missing FX session property counts as
      // active (fail closed on staleness).
      bool fxIsClosed = PythLazerLib.hasMarketSession(fx) &&
        PythLazerLib.getMarketSession(fx) ==
        PythLazerStructs.MarketSession.Closed;
      if (!fxIsClosed) {
        _requireFreshFeedObservation(fx);
      }
      int64 fxMantissa = PythLazerLib.getPrice(fx);
      require(fxMantissa > 0, 'PAO: non-positive fx');
      priceE18 = _combineHkdToUsd(priceE18, fxMantissa, fxExponent);
    }
  }

  /// @dev First feed carrying the pinned SIGNED id; reverts with the caller's
  ///   reason when absent. Feed identity comes from the signed bytes, so an
  ///   attacker cannot smuggle a different feed under the pinned id.
  function _findFeedById(
    PythLazerStructs.Feed[] memory feeds,
    uint32 feedId,
    string memory missingReason
  ) private pure returns (PythLazerStructs.Feed memory) {
    for (uint256 i = 0; i < feeds.length; i++) {
      if (PythLazerLib.getFeedId(feeds[i]) == feedId) {
        return feeds[i];
      }
    }
    revert(missingReason);
  }

  /// @dev The signed FeedUpdateTimestamp is in microseconds. Fail closed when
  ///   the property is absent from the signed payload.
  function _requireFreshFeedObservation(
    PythLazerStructs.Feed memory feed
  ) private view {
    require(
      PythLazerLib.hasFeedUpdateTimestamp(feed),
      'PAO: no feed timestamp'
    );
    _requireTimelyFeedTimestamp(
      PythLazerLib.getFeedUpdateTimestamp(feed) / 1_000_000
    );
  }

  /// @dev Two-sided per-feed observation window, symmetric with the envelope
  ///   check: at most feedMaxAgeSeconds old and at most
  ///   MAX_FUTURE_DRIFT_SECONDS ahead of the chain clock (a future-dated
  ///   observation would otherwise read as "fresh" indefinitely). `internal`
  ///   so tests can reach the reject branch: recorded signed payloads all
  ///   carry past observation timestamps and cannot be re-signed.
  function _requireTimelyFeedTimestamp(uint64 feedTsSec) internal view {
    require(
      block.timestamp <= uint256(feedTsSec) + feedMaxAgeSeconds,
      'PAO: stale feed observation'
    );
    require(
      uint256(feedTsSec) <= block.timestamp + MAX_FUTURE_DRIFT_SECONDS,
      'PAO: future feed observation'
    );
  }

  /// @dev priceE18 = mantissa * 10^(18 + exp). Handles both signs of (18 + exp).
  function _mantissaToE18(
    int64 mantissa,
    int16 exp
  ) private pure returns (uint256) {
    uint256 m = uint256(uint64(mantissa)); // mantissa > 0 checked by caller
    int256 e = int256(18) + int256(exp);
    if (e >= 0) {
      return m * (10 ** uint256(e));
    }
    return m / (10 ** uint256(-e));
  }

  /// @dev usd = hkd / fxRate, where fxRate = fxMantissa * 10^fxExp (HKD per USD).
  ///   usd_e18 = hkdE18 * 10^(-fxExp) / fxMantissa. fxExp enforced <= 0 in config.
  function _combineHkdToUsd(
    uint256 hkdE18,
    int64 fxMantissa,
    int16 fxExp
  ) private pure returns (uint256) {
    uint256 fxm = uint256(uint64(fxMantissa)); // > 0 checked by caller
    uint256 scale = 10 ** uint256(int256(-fxExp)); // 10^(-fxExp), fxExp <= 0
    // Same peg check as the off-chain updater: 7.5 <= fxRate <= 8.0 HKD per USD.
    require(
      fxm * 10 >= FX_PEG_MIN_X10 * scale && fxm * 10 <= FX_PEG_MAX_X10 * scale,
      'PAO: fx out of peg'
    );
    return (hkdE18 * scale) / fxm; // multiply before divide
  }

  function _priceE18ToAnswer(uint256 priceE18) private pure returns (int256) {
    require(
      priceE18 > 0 && priceE18 <= uint256(type(uint128).max),
      'PAO: price out of range'
    );
    return int256(priceE18);
  }

  // ---------------------------------------------------------------------------
  // Shared write path (same guards as ImmutableBackendPriceOracle)
  // ---------------------------------------------------------------------------
  function _validateAnswer(int256 answer) private pure {
    require(answer > 0, 'PAO: price must be > 0');
    require(uint256(answer) <= type(uint128).max, 'PAO: price exceeds uint128');
  }

  /// @dev Future side of the payload freshness window: with the per-path
  ///   maxAgeSeconds stale bound this forces the signed timestamp into
  ///   [block.timestamp - maxAgeSeconds, block.timestamp + MAX_FUTURE_DRIFT_SECONDS].
  ///   Runs before _requireNewerPayload so a future-dated payload can never
  ///   advance lastPayloadTimestamp. `internal` so tests can reach the reject
  ///   branch: recorded signed payloads all carry past timestamps and cannot
  ///   be re-signed.
  function _requireNotFutureDated(uint64 payloadTsSec) internal view {
    require(
      uint256(payloadTsSec) <= block.timestamp + MAX_FUTURE_DRIFT_SECONDS,
      'PAO: future payload'
    );
  }

  /// @dev Replay hardening: every accepted write must carry a STRICTLY newer
  ///   signed payload timestamp than the last accepted one. Runs after the
  ///   freshness gate and before any state write; a revert leaves
  ///   lastPayloadTimestamp untouched.
  function _requireNewerPayload(uint64 payloadTsSec) private {
    require(payloadTsSec > lastPayloadTimestamp, 'PAO: payload not newer');
    lastPayloadTimestamp = payloadTsSec;
  }

  /// @dev Clamp `target` to at most maxUpdateBps away from the previous answer,
  ///   moving toward it. The off-chain updater computes the same integer
  ///   result, so it can predict the written answer. `internal` so tests can
  ///   drive this math directly.
  function _boundToMaxUpdate(int256 target) internal view returns (int256) {
    if (maxUpdateBps == 0 || _latestRound == 0) return target;
    int256 prev = _answers[_latestRound];
    if (prev <= 0) return target;
    int256 maxMove = (prev * int256(uint256(maxUpdateBps))) / 10000;
    require(maxMove > 0, 'PAO: no valid bounded step');
    if (target > prev + maxMove) return prev + maxMove;
    if (target < prev - maxMove) return prev - maxMove;
    return target;
  }

  function _writeNewRound(int256 answer) internal {
    require(
      _latestRound == 0 || lastUpdateBlock < block.number,
      'PAO: already updated this block'
    );
    if (minUpdateIntervalSeconds > 0 && _latestRound > 0) {
      require(
        block.timestamp >= _updatedAt[_latestRound] + minUpdateIntervalSeconds,
        'PAO: update too soon'
      );
    }
    _latestRound += 1;
    lastUpdateBlock = block.number;
    _answers[_latestRound] = answer; // 1e18 scaled
    _startedAt[_latestRound] = block.timestamp;
    _updatedAt[_latestRound] = block.timestamp;
    emit PriceUpdated(_latestRound, answer, block.timestamp);
  }

  // ---------------------------------------------------------------------------
  // AggregatorV3Interface
  // ---------------------------------------------------------------------------
  function decimals() external pure override returns (uint8) {
    return DECIMALS;
  }

  function description() external pure override returns (string memory) {
    return 'PythAnchoredOracle';
  }

  function latestRoundData()
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    roundId = _latestRound;
    answer = _answers[_latestRound];
    startedAt = _startedAt[_latestRound];
    updatedAt = _updatedAt[_latestRound];
    answeredInRound = _latestRound;
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    require(_roundId != 0 && _roundId <= _latestRound, 'PAO: No data present');
    roundId = _roundId;
    answer = _answers[_roundId];
    startedAt = _startedAt[_roundId];
    updatedAt = _updatedAt[_roundId];
    answeredInRound = _roundId;
  }
}
