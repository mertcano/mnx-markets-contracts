// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from '../libraries/Types.sol';

/**
 * @title IAccountManager
 * @notice Manages sub-account relationships for all Perpetual contracts
 * @dev Centralizes sub-account authorization so users only need one transaction
 *      to authorize session keys across all markets (current and future)
 */
interface IAccountManager {
    /**
     * @notice Emitted when a sub account relationship is updated
     * @param user      The main account
     * @param operator  The operator/session key being approved or revoked
     * @param approved  True for approval, false for revocation
     */
    event SubAccountUpdate(
        address indexed user,
        address indexed operator,
        bool approved
    );

    /**
     * @notice Grants or revokes permission for another account to perform actions on behalf of the sender
     * @dev The zero address is never a valid operator.
     * @param  operator  The account that is approved or disapproved
     * @param  approved  True for approval, false for disapproval
     */
    function setSubAccount(address operator, bool approved) external;

    /**
     * @notice Gives up the caller's own grant on an ordinary user account.
     * @dev System-account operators remain controlled by their controller.
     */
    function renounceSubAccount(address user) external;

    /**
     * @notice Registers a system account and permanently binds it to the caller.
     * @dev Callable only by an approved controller, and only for a contract
     * whose `controller()` returns that caller.
     */
    function registerSystemAccount(address account) external;

    /**
     * @notice Sets or clears the global sub-account flag for a system account's
     * operator.
     * @dev Grants no market authority: `accountMarketPermission` never reads
     * this flag for a system account, so it only changes `isSubAccount`. Market
     * authority is set with `setSystemMarketPermission`. Only the controller the
     * account is bound to may call it.
     */
    function setSystemSubAccount(
        address user,
        address operator,
        bool approved
    ) external;

    /**
     * @notice Allows or revokes a contract's ability to control system accounts.
     * @dev Approval is necessary but never sufficient: changing an account's
     * operators additionally requires that account to be bound to the caller.
     */
    function setApprovedController(
        address controller,
        bool approved
    ) external;

    /**
     * @notice Returns the controller an account is bound to, or the zero address.
     */
    function controllerOf(address account) external view returns (address);

    /**
     * @notice Returns the global `subAccounts` approval of `operator` for `user`
     * @dev Not the market authorization check: markets call
     * `accountMarketPermission`, which never reads this flag for a system account
     * and authorizes an ordinary user to act for itself.
     * @param  user      The main account
     * @param  operator  The operator to check
     * @return           True if both addresses are nonzero and the global approval is set
     */
    function isSubAccount(address user, address operator)
        external
        view
        returns (bool);

    /**
     * @notice Sets what an operator may do for a system account in one market.
     * @dev Callable only by the controller the account is bound to. Audit #38.
     */
    function setSystemMarketPermission(
        address account,
        address operator,
        address market,
        Types.MarketPermission permission
    ) external;

    /**
     * @notice What `operator` may do for `account` in `market`.
     * @dev The authorization entry point for markets. System accounts are
     * market-scoped and never fall back to the global sub-account approval;
     * ordinary users keep their existing global behavior. While an account's
     * controller is not approved, every grant evaluates to NONE; the stored
     * records survive and re-approval restores them.
     */
    function accountMarketPermission(
        address account,
        address operator,
        address market
    ) external view returns (Types.MarketPermission);

    /**
     * @notice The stored market permission, without the ordinary-user fallback.
     */
    function systemMarketPermission(
        address account,
        address operator,
        address market
    ) external view returns (Types.MarketPermission);

    /**
     * @notice Whether an account has a controller binding, i.e. is a system account.
     */
    function isSystemAccount(address account) external view returns (bool);
}
