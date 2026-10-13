// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";
import {TypedSignature} from "../libraries/TypedSignature.sol";

interface IPerpetual {
    /**
     * @notice Emitted when the account-authorization dependency changes.
     * @param previousAccountManager Previously configured AccountManager.
     * @param newAccountManager Newly configured AccountManager.
     */
    event AccountManagerUpdate(
        address indexed previousAccountManager,
        address indexed newAccountManager
    );

    //
    // STRUCTS
    //

    /// @dev Argument for the trade method
    struct TradeArg {
        // index of taker account in first argument to trade function
        uint128 takerIndex;
        // index of maker account in first argument to trade function
        uint128 makerIndex;
        // address of a trader contract implementing the Trader interface and
        address trader;
        // A struct of type TradeData. Passed in as bytes since TradeData type is different for each trader
        bytes data;
    }

    /// @dev Addresses used across the contract
    struct Addresses {
        /// @notice address of the contract to be used for performing margin maths
        address marginMath;
        /// @notice address of the oracle contract providing index price
        address oracle;
        /// @notice address of the funder contract providing the per-second funding rate
        /// (each one-hour window's rate divided by FUNDING_RATE_WINDOW)
        address funder;
        /// @notice address of the margin bank contract used to store account bank balances
        address marginBank;
        /// @notice address of the evaluator contract
        address evaluator;
        /// @notice address of the fee pool. Trade fees accrue in feePoolAccruedAmt and move
        /// here only when the owner calls transferAccruedFee; an under-collateralized
        /// delisting can write the accrual down first.
        address feePool;
        /// @notice address of the guardian contract
        address guardian;
        /// @notice address of the signature verifier contract for margin/leverage adjustments
        address signatureVerifier;
    }

    /**
     * @notice Performs one or multiple matches between two or more trading parties
     * @param  _accounts  A sorted, unique account table referenced by trade indices
     * @param  _trades    Trades to execute in this batch
     */
    function trade(
        address[] calldata _accounts,
        TradeArg[] calldata _trades
    ) external;

    /**
     * @notice Settles a position in a delisted market once `delistClaimsOpenAt()` is reached,
     *  crediting the account's MarginBank balance. The gross claim is the position's equity at
     *  the frozen `delistingPrice` (owner-supplied after `delistPerpetualAtSettlementPrice`)
     *  and `delistIndex`. A registered claim is paid `claim * delistClaimRatioE18`, below the
     *  claim when collateral falls short; an unregistered account gets at most the collateral
     *  not reserved for registered claims. Every payout is capped at the market's collateral
     *  net of accrued fees.
     * @param  _account account with a position to close
     */
    function closePosition(address _account) external;

    /**
     * @notice Owner-driven batch settlement after delisting. Closes each
     *  listed account at the recorded `delistingPrice` and transfers the
     *  resulting margin back to the user's MarginBank balance. Used by the
     *  delist + redeploy operator workflow so users don't have to call
     *  `closePosition` themselves. Accounts whose position is already
     *  zero are silently skipped. Callable only after `CLOSE_DELAY()` has
     *  elapsed since the owning delist call.
     * @param _accounts list of accounts whose positions should be closed
     */
    function closePositionForAccounts(address[] memory _accounts) external;

    /**
     * @notice Owner-only escape hatch for a malicious or mistaken delist.
     *  Resets `delisted`, `delistingPrice`, and `delistedAt` to zero so
     *  normal trading resumes. Normally callable inside the `CLOSE_DELAY()`
     *  window; early claimant-population finalization extends both abort and
     *  settlement through the funding grace. In either case abort closes at
     *  the exact boundary where position settlement becomes possible.
     */
    function abortDelist() external;

    /**
     * @notice Delists the market at an explicit owner-supplied settlement
     * price without mutating the oracle.
     */
    function delistPerpetualAtSettlementPrice(uint128 _settlementPrice) external;

    /**
     * @notice Delay between delisting and settlement, in seconds.
     */
    function CLOSE_DELAY() external view returns (uint128);

    /**
     * @notice One-time initializer for upgraded markets that predate the
     * configurable delist close delay.
     */
    function initializeDelistCloseDelay(uint128 _delistCloseDelaySeconds) external;

    /**
     * @notice One-time initializer for upgraded markets that predate the
     * pinned binary-future market flag.
     */
    function initializeBinaryFutureMarketFlag() external;

    /**
     * @notice Sets a new Fee Pool contract.
     * @param  _feePool  The address of the new fee pool.
     */
    function setFeePool(address _feePool) external;

    /**
     * @notice Sets a new evaluator contract after Perpetual-side invariant checks.
     * @param _evaluator The address of the new evaluator contract.
     */
    function setEvaluator(address _evaluator) external;

    /**
     * @notice Sets the default taker fee rate. IsolatedTrader charges it to the fill's
     *  taker side (order B), whether that order is a market or a limit order.
     * @param  _defaultTakerFee  The new taker fee rate on fill notional,
     *                        as a fixed-point number with 18 decimals.
     */
    function setDefaultTakerFee(uint128 _defaultTakerFee) external;

    /**
     * @notice Sets the default maker fee rate. IsolatedTrader charges it to the fill's
     *  maker side (order A), whether that order is a market or a limit order.
     * @param  _defaultMakerFee  The new maker fee rate on fill notional,
     *                        as a fixed-point number with 18 decimals.
     */
    function setDefaultMakerFee(uint128 _defaultMakerFee) external;

    /**
     * @notice Updates global funding index using current funding rate and oracle price.
     */
    function updateGlobalIndex() external;

    /**
     * @notice Attempts to move a positive-equity distressed position into the
     * backstop vault child selected for this market.
     * @dev Inheritance is permitted only when equity is greater than zero and
     * strictly below the configured backstop trigger. The position's remaining
     * isolated margin and positive residual equity transfer to the child as an
     * intentional insurance fee for assuming the position's tail risk.
     */
    function attemptBackstopInheritance(address account) external returns (bool);

    /**
     * @notice Updates status of trading for this market
     * @dev Must be called by the Guardian
     * @param _newStatus status of trading for this market. If not allowed then no new trades can be performed
     */
    function setTradingStatus(Types.GuardianStatus _newStatus) external;

    /// @notice Returns maintenance margin required to sustain a position
    function maintenanceMarginRequired() external view returns (int256);

    /// @notice Returns initial margin required to open a position
    function initialMarginRequired() external view returns (int256);

    /// @notice Returns default maker fee
    function defaultMakerFee() external view returns (uint128);

    /// @notice Returns default taker fee
    function defaultTakerFee() external view returns (uint128);

    /**
     * @notice Get the balance of an account
     * @param  _account The address of the account to query the balances of.
     */
    function getAccountBalance(address _account)
        external
        view
        returns (Types.PositionBalance memory);

    function accountFundingAdjustedEquity(address account)
        external
        view
        returns (int256 equity);

    /**
     * @notice Returns true if trading is allowed for this market else false
     */
    function isTradingAllowed() external view returns (bool);

    /**
     * @notice Returns true if account is an authorized settlement operator.
     */
    function settlementOperators(address account) external view returns (bool);

    /**
     * @notice Adjust leverage for an account
     * @param  _account       The account to adjust leverage for
     * @param  _leverage      The new leverage value (1e18 format)
     * @param  _maxMarginIn   Max collateral the signer authorizes moving into
     *                        the position for this adjustment (1e18 format)
     * @param  _minMarginOut  Min collateral the signer requires moving out of
     *                        the position for this adjustment (1e18 format)
     * @param  _nonce         Unique nonce for replay protection
     * @param  _deadline      Last block timestamp the authorization is valid
     * @param  _signature     EIP-712 signature from the account owner or an operator authorized for it
     */
    function adjustLeverage(
        address _account,
        uint128 _leverage,
        uint128 _maxMarginIn,
        uint128 _minMarginOut,
        uint128 _nonce,
        uint64 _deadline,
        TypedSignature.Signature calldata _signature
    ) external;

    /**
     * @notice Add margin to an account's position
     * @param  _account    The account to add margin to
     * @param  _amount     The amount of margin to add (1e18 format)
     * @param  _nonce      Unique nonce for replay protection
     * @param  _deadline   Last block timestamp the authorization is valid
     * @param  _signature  EIP-712 signature from the account owner or an operator authorized for it
     */
    function addMargin(
        address _account,
        uint128 _amount,
        uint128 _nonce,
        uint64 _deadline,
        TypedSignature.Signature calldata _signature
    ) external;

    /**
     * @notice Remove margin from an account's position
     * @param  _account    The account to remove margin from
     * @param  _amount     The amount of margin to remove (1e18 format)
     * @param  _nonce      Unique nonce for replay protection
     * @param  _deadline   Last block timestamp the authorization is valid
     * @param  _signature  EIP-712 signature from the account owner or an operator authorized for it
     */
    function removeMargin(
        address _account,
        uint128 _amount,
        uint128 _nonce,
        uint64 _deadline,
        TypedSignature.Signature calldata _signature
    ) external;

    /**
     * @notice Remove up to a signed maximum from an account's position
     * @param  _account    The account to remove margin from
     * @param  _maxAmount  The maximum amount of margin to remove (1e18 format)
     * @param  _minAmount  The minimum amount that must be removed (1e18 format)
     * @param  _nonce      Unique nonce for replay protection
     * @param  _deadline   Last block timestamp the authorization is valid
     * @param  _signature  EIP-712 signature from the account owner or an operator authorized for it
     */
    function removeMarginUpTo(
        address _account,
        uint128 _maxAmount,
        uint128 _minAmount,
        uint128 _nonce,
        uint64 _deadline,
        TypedSignature.Signature calldata _signature
    ) external;

    /**
     * @notice Cancel every unused margin/leverage authorization below
     *  `_newMinimum` for the calling account.
     * @param  _newMinimum  The lowest nonce the account will still honour
     */
    function invalidateMarginNoncesUpTo(uint128 _newMinimum) external;

    /**
     * @notice Point this market at a new SignatureVerifier. Must land in the
     *  same campaign run as the matching implementation upgrade — see the
     *  implementation's NatSpec for the mismatch window.
     * @param  _signatureVerifier  The new SignatureVerifier contract address
     */
    function setSignatureVerifier(address _signatureVerifier) external;

    /**
     * @notice The lowest margin/leverage authorization nonce an account still
     *  honours. Zero means no authorization has been cancelled.
     */
    function minimumMarginNonce(address account)
        external
        view
        returns (uint128);

    /**
     * @notice Returns the account's global AccountManager sub-account approval for `operator`.
     *  This market does not authorize with it: orders, margin and leverage signatures, and
     *  `closePosition` use {accountMarketPermission}, which ignores this approval for system
     *  accounts and treats an ordinary account as authorized for itself.
     *
     * @param  account   The account to query the operator for.
     * @param  operator  The address of the operator to query the status of.
     * @return           True if the operator is a sub account of the account, false otherwise.
     */
    function isSubAccount(address account, address operator)
        external
        view
        returns (bool);

    /**
     * @notice What `operator` may do for `account` in THIS market (audit #38).
     *
     * @dev System accounts are market-scoped and never fall back to a global
     * sub-account approval; ordinary users keep their existing global behavior.
     *
     * @param  account   The account to query the operator for.
     * @param  operator  The address of the operator to query the status of.
     * @return           NONE, REDUCE_ONLY, or ACTIVE for this market.
     */
    function accountMarketPermission(address account, address operator)
        external
        view
        returns (Types.MarketPermission);

    /**
     * @notice Returns true if this is a binary future market
     * @dev Binary markets have minPrice=1, maxPrice=1e18, maxFundingRate=0
     */
    function isBinaryFutureMarket() external view returns (bool);
}
