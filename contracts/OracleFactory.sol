// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ImmutableBackendPriceOracle} from './ImmutableBackendPriceOracle.sol';
import {ImmutableBinaryBackendPriceOracle} from './ImmutableBinaryBackendPriceOracle.sol';
import {IOracleFactory} from './interfaces/IOracleFactory.sol';
import {PythAnchoredOracle} from './PythAnchoredOracle.sol';

/**
 * @title OracleFactory
 * @author MNX Markets <help@mnx.fi>
 * @notice Mints non-upgradeable price oracles and records what it minted.
 *
 * This contract is itself immutable and non-upgradeable: no proxy, no
 * initializer, no owner, no admin function of any kind. It has no state a
 * caller can change except the append-only local registry below, which only
 * `deploy*` writes and which can never be cleared or overwritten. A factory
 * generation may name one immutable predecessor so upgrades add oracle types
 * without invalidating the already-minted fleet.
 *
 * WHY IT EXISTS. `isFactoryOracle` is the predicate the Perpetual
 * implementation checks inside both `setOracle` and the oracle argument
 * of `Perpetual.initialize()`, with the factory address a Solidity `immutable`
 * of that implementation — no setter exists or can exist, so changing
 * factories is an implementation upgrade. Every implementation this factory
 * can construct is non-upgradeable and stamps accepted rounds from
 * `block.timestamp`, so "installed from the factory" implies "cannot mint a
 * future-dated round". That turns audit #79 from a checker-side mitigation
 * into a producer-side impossibility.
 *
 * DEPLOY IS PERMISSIONLESS. Creating an oracle is not a grant of trust:
 * nothing happens until an owner installs it with `Perpetual.setOracle`,
 * which still runs the round-metadata gate, the ADL replacement-capacity
 * invariant, and the audit #53 continuity check. Keeping creation open
 * means an emergency rotation is deploy-and-install rather than
 * deploy-request-approve-install, and it removes the factory as a
 * single-key chokepoint on incident response.
 *
 * TYPES ARE CLOSED AT DEPLOYMENT. This generation can mint the generic
 * percentage-bounded feed, the Pyth-anchored feed, and the
 * complement-symmetric binary feed. Adding a later implementation still means
 * deploying a new factory and upgrading the Perpetual implementation that
 * pins it — deliberately a loud operation. Enum members only append so a
 * successor can read inherited type values without reinterpretation.
 */
contract OracleFactory {
  /// @notice Oracle implementations this factory generation can mint.
  /// @dev New members append so existing registry values keep their index.
  enum OracleType {
    BACKEND_PRICE,
    PYTH_ANCHORED,
    BINARY_BACKEND_PRICE
  }

  /// @notice Price scaling every minted oracle uses. `Perpetual.setOracle`
  /// requires exactly 18 ('P45'), so any other value would mint an oracle
  /// that can never be installed.
  uint8 public constant REQUIRED_DECIMALS = 18;

  /// @notice Bounds on the per-update movement cap, in basis points.
  /// @dev Perpetual independently requires `(0, 10000]` ('P54') and then ties
  /// the value to market-take bounds and IMR through the ADL
  /// replacement-capacity invariant ('P57'/'P58'). This range is deliberately
  /// only a coarse sanity envelope and does NOT restate that invariant:
  /// duplicating it here would create two copies of the same rule that can
  /// drift apart, and Perpetual is the copy that actually gates installation.
  /// Every deployed percentage-capped oracle is configured at 250 bps;
  /// binary oracles have no bps cap and are bounded by `riskFractionE18`
  /// instead. 1000 leaves generous headroom for a wider-IMR market while
  /// keeping a nearly unbounded feed unmintable.
  uint128 public constant MIN_MAX_UPDATE_BPS = 1;
  uint128 public constant MAX_MAX_UPDATE_BPS = 1000;

  /// @notice Upper bound on the advertised maximum age, in seconds. Zero is
  /// permitted and means "no advertised bound".
  /// @dev The oracle's own staleness field is advisory: Perpetual enforces
  /// its own `oracleMaxStalenessSeconds` against `updatedAt`, so the factory
  /// has no safety basis to forbid zero. The ceiling exists only so an
  /// absurd value cannot be advertised as if it were meaningful. Deployed
  /// values today are 900s for the equity feeds and 4500s for the
  /// hourly SemiAnalysis feed.
  uint128 public constant MAX_MAX_STALENESS_SECONDS = 86400;

  /// @notice Upper bound on the minimum interval between accepted updates.
  /// @dev Zero remains supported for generic feeds. Above one hour a feed
  /// would brick normal publishing.
  uint128 public constant MAX_MIN_UPDATE_INTERVAL_SECONDS = 3600;

  /// @notice Exact interval required for binary oracle updates.
  /// @dev The k=1 margin proof assumes one 45-second liquidation-processing
  /// window between accepted updates. This is exact, not a lower bound: a
  /// faster cadence shortens the liquidation window, while a slower one no
  /// longer matches the operating assumptions reviewed with that proof.
  uint128 public constant BINARY_ORACLE_MIN_UPDATE_INTERVAL_SECONDS = 45;

  /// @notice Reviewed Pyth Lazer signing authority on MegaETH.
  /// @dev Both the signer and its registry expiry are pinned by the factory;
  /// callers cannot substitute a different oracle trust root. Provenance:
  /// MegaETH mainnet (chain 4326), canonical PythLazer
  /// 0xACeA761c27A909d4D3895128EBe6370FDE2dF481 at block 23161340;
  /// storage slot 0 held this signer and slot 1 held 0x7a0a0fa8 =
  /// 2047479720 (2034-11-18T16:22:00Z).
  address public constant PYTH_LAZER_TRUSTED_SIGNER =
    0x26FB61A864c758AE9fBA027a96010480658385B9;
  uint256 public constant PYTH_LAZER_SIGNER_EXPIRES_AT = 2047479720;

  /// @notice Factory ceilings for caller-supplied Pyth acceptance limits.
  /// @dev The child constructor owns nonzero and feed-shape validation. These
  /// bounds only prevent a permissionless caller from minting a factory-
  /// registered oracle outside the reviewed trust envelope.
  uint64 public constant MAX_PYTH_SIGNED_ENVELOPE_AGE_SECONDS = 900;
  uint32 public constant MAX_PYTH_SECONDARY_BAND_BPS = 2500;
  uint64 public constant MAX_PYTH_FEED_AGE_SECONDS = 21600;
  uint32 public constant PYTH_USD_HKD_FX_FEED_ID = 1510;

  /// @notice Prior attested factory whose minted fleet remains accepted.
  /// @dev Zero marks the root generation. The reference is immutable, so no
  /// caller can point this generation at a different predecessor.
  IOracleFactory public immutable predecessorFactory;

  /// @dev Append-only registry for this generation only. Use
  /// `isFactoryOracle` for the full local-plus-inherited predicate.
  mapping(address => bool) private _isLocalFactoryOracle;

  /// @dev Type registry for this generation only. Public type lookup follows
  /// the same predecessor chain as `isFactoryOracle`.
  mapping(address => OracleType) private _localFactoryOracleType;

  /// @notice Every oracle minted here, in deployment order, so inventory and
  /// rotation tooling can enumerate the fleet without log scraping.
  address[] public deployedOracles;

  event OracleDeployed(
    address indexed oracle,
    OracleType indexed oracleType,
    address indexed deployer,
    address owner,
    address initialUpdater,
    int256 initialAnswer,
    uint128 maxStalenessSeconds,
    uint128 maxUpdateBps,
    uint128 minUpdateIntervalSeconds,
    string description
  );

  event BinaryOracleDeployed(
    address indexed oracle,
    OracleType indexed oracleType,
    address indexed deployer,
    address owner,
    address initialUpdater,
    int256 initialAnswer,
    uint128 maxStalenessSeconds,
    uint128 riskFractionE18,
    uint128 minUpdateIntervalSeconds,
    string description
  );

  /**
   * @param predecessorFactory_ Prior reviewed factory generation, or zero for
   * the root generation. Attestation tooling binds this exact immutable value
   * to the reviewed runtime before the factory is trusted.
   */
  constructor(IOracleFactory predecessorFactory_) {
    require(
      address(predecessorFactory_) == address(0) ||
        address(predecessorFactory_).code.length > 0,
      'OF: predecessor has no code'
    );
    predecessorFactory = predecessorFactory_;
  }

  /**
   * @notice True for every oracle minted locally or by an immutable predecessor.
   * @dev The recursive bridge preserves the complete accepted fleet across
   * successive factory generations. Deployment chronology plus the immutable
   * reference prevents a cycle from being constructed.
   */
  function isFactoryOracle(address oracle) public view returns (bool) {
    if (_isLocalFactoryOracle[oracle]) return true;
    IOracleFactory predecessor = predecessorFactory;
    return
      address(predecessor) != address(0) && predecessor.isFactoryOracle(oracle);
  }

  /// @notice True only when this generation minted `oracle`.
  function isLocalFactoryOracle(address oracle) external view returns (bool) {
    return _isLocalFactoryOracle[oracle];
  }

  /**
   * @notice Type of a locally or predecessor-minted oracle.
   * @dev As with the old public mapping, this returns enum member zero for an
   * unregistered address. Call `isFactoryOracle` before relying on the type.
   */
  function factoryOracleType(
    address oracle
  ) external view returns (OracleType) {
    if (_isLocalFactoryOracle[oracle]) {
      return _localFactoryOracleType[oracle];
    }
    IOracleFactory predecessor = predecessorFactory;
    if (
      address(predecessor) != address(0) && predecessor.isFactoryOracle(oracle)
    ) {
      return OracleFactory(address(predecessor)).factoryOracleType(oracle);
    }
    return OracleType.BACKEND_PRICE;
  }

  /**
   * @notice Type recorded by this generation for `oracle`.
   * @dev Reverts for inherited and unknown addresses so callers cannot mistake
   * the enum's zero value for a local generic oracle.
   */
  function localFactoryOracleType(
    address oracle
  ) external view returns (OracleType) {
    require(_isLocalFactoryOracle[oracle], 'OF: oracle not locally minted');
    return _localFactoryOracleType[oracle];
  }

  /// @notice Number of oracles minted by this generation, excluding predecessors.
  function deployedOracleCount() external view returns (uint256) {
    return deployedOracles.length;
  }

  /**
   * @notice Deploy a non-upgradeable backend price oracle, ready to install.
   * @dev Permissionless by design; see the contract-level note. The oracle
   * comes out with `initialUpdater` already authorized and `initialOwner`
   * already owning it, so a rotation is deploy-then-`setOracle` with no
   * intervening role calls.
   *
   * Parameter validation is split deliberately: range checks that belong to
   * THIS factory generation live here, while checks the oracle already owns
   * (positive answer, answer within `uint128`, non-empty description) are
   * left to its constructor rather than restated.
   *
   * @param initialOwner Receives the owner role. The factory never defaults
   * ownership to the caller, so the caller ends up owning the oracle only if
   * it names itself here.
   * @param initialUpdater The only address authorized to publish prices at
   * deployment; the owner can authorize more.
   * @param initialAnswer First round's price, 1e18 scaled.
   * @param description_ Human-readable feed label.
   * @return oracle Address of the newly deployed oracle.
   */
  function deployBackendPriceOracle(
    address initialOwner,
    address initialUpdater,
    int256 initialAnswer,
    string calldata description_,
    uint128 maxStalenessSeconds,
    uint128 maxUpdateBps,
    uint128 minUpdateIntervalSeconds
  ) external returns (address oracle) {
    _requireSharedBounds(
      maxStalenessSeconds,
      maxUpdateBps,
      minUpdateIntervalSeconds
    );

    oracle = address(
      new ImmutableBackendPriceOracle(
        initialOwner,
        initialUpdater,
        initialAnswer,
        REQUIRED_DECIMALS,
        description_,
        maxStalenessSeconds,
        maxUpdateBps,
        minUpdateIntervalSeconds
      )
    );

    _isLocalFactoryOracle[oracle] = true;
    _localFactoryOracleType[oracle] = OracleType.BACKEND_PRICE;
    deployedOracles.push(oracle);

    emit OracleDeployed(
      oracle,
      OracleType.BACKEND_PRICE,
      msg.sender,
      initialOwner,
      initialUpdater,
      initialAnswer,
      maxStalenessSeconds,
      maxUpdateBps,
      minUpdateIntervalSeconds,
      description_
    );
  }

  /**
   * @notice Deploy an immutable complement-symmetric binary payout oracle.
   * @dev The exact approved update interval is mandatory because the market's
   * k=1 replacement-capacity proof assumes liquidation processing gets one
   * reviewed cadence window between accepted updates.
   */
  function deployBinaryBackendPriceOracle(
    address initialOwner,
    address initialUpdater,
    int256 initialAnswer,
    string calldata description_,
    uint128 maxStalenessSeconds,
    uint128 riskFractionE18,
    uint128 minUpdateIntervalSeconds
  ) external returns (address oracle) {
    require(
      maxStalenessSeconds <= MAX_MAX_STALENESS_SECONDS,
      'OF: maxStalenessSeconds out of range'
    );
    require(
      riskFractionE18 > 0 && riskFractionE18 <= 1e18,
      'OF: binary risk fraction out of range'
    );
    require(
      minUpdateIntervalSeconds == BINARY_ORACLE_MIN_UPDATE_INTERVAL_SECONDS,
      'OF: binary update interval must be 45s'
    );

    oracle = address(
      new ImmutableBinaryBackendPriceOracle(
        initialOwner,
        initialUpdater,
        initialAnswer,
        REQUIRED_DECIMALS,
        description_,
        maxStalenessSeconds,
        riskFractionE18,
        minUpdateIntervalSeconds
      )
    );

    _isLocalFactoryOracle[oracle] = true;
    _localFactoryOracleType[oracle] = OracleType.BINARY_BACKEND_PRICE;
    deployedOracles.push(oracle);

    emit BinaryOracleDeployed(
      oracle,
      OracleType.BINARY_BACKEND_PRICE,
      msg.sender,
      initialOwner,
      initialUpdater,
      initialAnswer,
      maxStalenessSeconds,
      riskFractionE18,
      minUpdateIntervalSeconds,
      description_
    );
  }

  /**
   * @notice Deploy a non-upgradeable Pyth-anchored oracle, ready to install.
   * @dev The Pyth signer and expiry are factory-pinned. The caller supplies
   * the market's reviewed feed identity and may choose limits only within the
   * factory's ceilings; the child constructor retains its stricter nonzero
   * and feed-shape validation.
   */
  function deployPythAnchoredOracle(
    address initialOwner,
    address initialUpdater,
    int256 initialAnswer,
    uint128 maxStalenessSeconds,
    uint128 maxUpdateBps,
    uint128 minUpdateIntervalSeconds,
    PythAnchoredOracle.LazerConfig calldata cfg
  ) external returns (address oracle) {
    _requireSharedBounds(
      maxStalenessSeconds,
      maxUpdateBps,
      minUpdateIntervalSeconds
    );
    require(
      cfg.maxAgeSeconds <= MAX_PYTH_SIGNED_ENVELOPE_AGE_SECONDS,
      'OF: Pyth maxAge out of range'
    );
    require(
      cfg.secondaryBandBps <= MAX_PYTH_SECONDARY_BAND_BPS,
      'OF: Pyth band out of range'
    );
    require(
      cfg.feedMaxAgeSeconds <= MAX_PYTH_FEED_AGE_SECONDS,
      'OF: Pyth feedMaxAge out of range'
    );
    require(
      cfg.fxFeedId == 0 || cfg.fxFeedId == PYTH_USD_HKD_FX_FEED_ID,
      'OF: unreviewed Pyth FX feed'
    );
    require(
      cfg.fxFeedId != 0 || cfg.fxExponent == 0,
      'OF: FX exponent without feed'
    );

    oracle = address(
      new PythAnchoredOracle(
        initialOwner,
        initialUpdater,
        initialAnswer,
        maxStalenessSeconds,
        maxUpdateBps,
        minUpdateIntervalSeconds,
        PYTH_LAZER_TRUSTED_SIGNER,
        PYTH_LAZER_SIGNER_EXPIRES_AT,
        cfg
      )
    );

    _isLocalFactoryOracle[oracle] = true;
    _localFactoryOracleType[oracle] = OracleType.PYTH_ANCHORED;
    deployedOracles.push(oracle);

    emit OracleDeployed(
      oracle,
      OracleType.PYTH_ANCHORED,
      msg.sender,
      initialOwner,
      initialUpdater,
      initialAnswer,
      maxStalenessSeconds,
      maxUpdateBps,
      minUpdateIntervalSeconds,
      'PythAnchoredOracle'
    );
  }

  function _requireSharedBounds(
    uint128 maxStalenessSeconds,
    uint128 maxUpdateBps,
    uint128 minUpdateIntervalSeconds
  ) private pure {
    require(
      maxUpdateBps >= MIN_MAX_UPDATE_BPS && maxUpdateBps <= MAX_MAX_UPDATE_BPS,
      'OF: maxUpdateBps out of range'
    );
    require(
      maxStalenessSeconds <= MAX_MAX_STALENESS_SECONDS,
      'OF: maxStalenessSeconds out of range'
    );
    require(
      minUpdateIntervalSeconds <= MAX_MIN_UPDATE_INTERVAL_SECONDS,
      'OF: minUpdateIntervalSeconds out of range'
    );
  }
}
