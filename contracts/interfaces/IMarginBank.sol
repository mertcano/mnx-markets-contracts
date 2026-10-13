// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from '../libraries/Types.sol';
import {TypedSignature} from '../libraries/TypedSignature.sol';

interface IMarginBank {
  /// @dev `expiresAt` is appended at the end so the struct only grows. The
  /// upgrade initializer rejects any proxy with an outstanding historical
  /// request. Every request created after the clean cutover records a non-zero
  /// deadline; older entries are terminal and can never execute again.
  struct DirectWithdrawalRequest {
    address owner;
    address destination;
    uint128 amount;
    uint64 executableAt;
    bool executed;
    bool cancelled;
    uint64 expiresAt;
  }

  /**
   * @notice Deposits collateral token from caller's address to provided
   * account address in margin bank.
   * @dev the caller must approve margin bank to take funds on their behalf
   * from collateral token before invoking this method. Amount is expected to
   * be in 18-decimal USDM raw units.
   * @param  _account receiver account address
   * @param  _amount amount of tokens to be deposited
   * @return true if deposit successful.
   */
  function depositToBank(
    address _account,
    uint128 _amount
  ) external returns (bool);

  /**
   * @notice Deposits collateral using an EIP-2612 permit instead of a separate approve transaction.
   * @dev Gasless deposits must be relayed through the ERC-2771 trusted forwarder.
   *      The permit owner is deliberately bound to msgSender() so the same signed
   *      calldata authenticates the token owner and destination account; a bare
   *      permit authorizes an amount, but not the `_account` receiving credit.
   *      Amount is expected to be in 18-decimal USDM raw units.
   * @param _account receiver account address
   * @param _amount amount of tokens to deposit
   * @param _deadline permit deadline
   * @param _v permit signature v
   * @param _r permit signature r
   * @param _s permit signature s
   * @return true if deposit successful.
   */
  function depositToBankWithPermit(
    address _account,
    uint128 _amount,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (bool);

  /**
   * @notice Deposits the caller's full approved USDM allowance for the provided account.
   * @dev Intended for exact-allowance routed contract-call flows, such as the
   *      Daimo Pay router. Infinite approvals are unsupported here; callers with
   *      standing approvals should use depositToBank with an explicit amount.
   *      Amount is in 18-decimal USDM raw units.
   * @param _account receiver account address
   * @return true if deposit successful.
   */
  function depositFullAllowanceToBank(address _account) external returns (bool);

  /**
   * @notice Deposits the same collateral amount for multiple accounts in one transaction.
   * @dev Caller must approve MarginBank to pull the total amount. Amount is in 18-decimal USDM raw units.
   * @param _accounts receiver account addresses
   * @param _amount amount of tokens to deposit per account
   * @return true if deposit successful.
   */
  function depositToBankBatch(
    address[] calldata _accounts,
    uint128 _amount
  ) external returns (bool);

  /**
   * @notice Requests a fee-free delayed direct withdrawal from caller address to provided destination address
   * @param  _destination The address to which the tokens are transferred after execution.
   * @param  _amount The amount of USDM debited and transferred, in 18-decimal raw units.
   * @return requestId The created direct withdrawal request id.
   */
  function requestWithdrawFromBank(
    address _destination,
    uint128 _amount
  ) external returns (uint128 requestId);

  /**
   * @notice Executes a delayed direct withdrawal inside its execution window.
   * @dev Valid while `executableAt <= block.timestamp <= expiresAt`. Execution
   * at exactly `expiresAt` succeeds; one second later it reverts.
   * @param _requestId The direct withdrawal request id to execute.
   */
  function executeWithdrawFromBank(uint128 _requestId) external;

  /**
   * @notice Last timestamp at which a direct withdrawal request may execute.
   * @dev Returns the per-request `expiresAt`, or zero for an unknown request id.
   * @param _requestId The direct withdrawal request id to inspect.
   */
  function directWithdrawalExpiryAt(
    uint128 _requestId
  ) external view returns (uint64);

  /**
   * @notice Cancels a delayed direct withdrawal request.
   * @param _requestId The direct withdrawal request id to cancel.
   */
  function cancelWithdrawFromBank(uint128 _requestId) external;

  /**
   * @notice Withdraws margin tokens on behalf of an owner using their EIP-712 authorization.
   * @dev This is the instant relayed path: only owner-managed withdrawal relayers
   *      may submit the signed authorization, while users retain the permissionless
   *      timelocked request/execute direct path as the non-custodial escape hatch.
   *      Both paths are blocked while the Guardian has withdrawals paused.
   *      The implementation checks msg.sender for the relayer gate, not msgSender(),
   *      so the allowlist binds the actual transaction submitter.
   * @param _owner The owner whose bank balance is reduced.
   * @param _destination The address to which the tokens are transferred.
   * @param _amount The gross amount of USDM debited, in 18-decimal raw units.
   * @param _minimumAmountOut The minimum amount the destination must receive after fees.
   * @param _nonce Current per-owner withdrawal nonce.
   * @param _deadline Last timestamp at which the authorization is valid.
   * @param _signature The owner's EIP-712 signature.
   */
  function withdrawFromBankWithAuth(
    address _owner,
    address _destination,
    uint128 _amount,
    uint128 _minimumAmountOut,
    uint128 _nonce,
    uint64 _deadline,
    TypedSignature.Signature calldata _signature
  ) external;

  /**
   * @notice allows bank operators to transfer margin from an account to another account
   * @dev Called by bank operators (in this repository, `Perpetual`) for margin add/remove,
   * leverage adjustment, delisting close-outs, fee and residual sweeps, and backstop
   * inheritance. Batch trade settlement uses `transferMarginToAccountSilent` instead and
   * emits no BankBalanceUpdate.
   * @param _account address of account from which to take margin out
   * @param _destination address of destination where funds are to be deposited
   * @param _amount amount of margin to be transfered
   */
  function transferMarginToAccount(
    address _account,
    address _destination,
    uint128 _amount
  ) external;

  /**
   * @notice allows bank operators to transfer margin silently (no BankBalanceUpdate event)
   * @dev settlement hot path helper; calldata matches transferMarginToAccount, and it
   * saves only the BankBalanceUpdate log
   * @param _account address of account from which to take margin out
   * @param _destination address of destination where funds are to be deposited
   * @param _amount amount of margin to be transfered
   */
  function transferMarginToAccountSilent(
    address _account,
    address _destination,
    uint128 _amount
  ) external;

  /**
   * @notice Registers a system account and permanently binds it to the caller.
   * @dev Callable only by an approved controller, and only for a contract
   * whose `controller()` returns that caller. System
   * accounts cannot use ordinary user deposit or withdrawal paths.
   */
  function registerSystemAccount(address _account) external;

  /**
   * @notice Allows or revokes a contract's ability to control system accounts.
   * @dev Approval is necessary but never sufficient: authority over an account
   * additionally requires that account to be bound to the caller.
   */
  function setApprovedController(address _controller, bool _approved) external;

  /**
   * @notice Returns the controller an account is bound to, or the zero address.
   */
  function controllerOf(address _account) external view returns (address);

  /**
   * @notice Sets the per-account cap on fresh external deposits net of
   * withdrawals.
   * @dev Amount is in 18-decimal USDM raw units. Trading profit/loss and
   * internal transfers do not affect cap usage. This is not a cap on balance,
   * retained principal, or account exposure.
   */
  function setExternalDepositCap(uint128 _cap) external;

  /**
   * @notice Marks accounts as exempt or non-exempt from the external deposit cap.
   */
  function setExternalDepositCapExemptAccounts(
    address[] calldata _accounts,
    bool _exempt
  ) external;

  /**
   * @notice Credits a system account after its controller has transferred
   * collateral tokens directly to MarginBank.
   * @dev The only way tokens enter a system account's bank balance from
   * outside. Safe against unbacked credits: reverts unless the bank's token
   * balance covers totalBankLiabilities after the credit.
   */
  function depositStrandedSystemAccountToken(
    address _srcAddress,
    address _systemAccount,
    uint128 _amount
  ) external returns (bool);

  /**
   * @notice Moves margin between two system accounts bound to the caller.
   * @dev Cross-controller movement is rejected, not authorized.
   */
  function transferFromSystemAccount(
    address _systemAccount,
    address _destinationSystemAccount,
    uint128 _amount
  ) external;

  /**
   * @notice Withdraws e18 margin from a registered system account.
   */
  function withdrawFromSystemAccount(
    address _systemAccount,
    address _destination,
    uint128 _amount
  ) external;

  /**
   * @notice Returns true if the address is registered as a system account.
   */
  function isSystemAccount(address _account) external view returns (bool);

  /**
   * @notice Add or remove a Bank Operator address.
   * @dev Must be called by the owner.
   * @param  _operator  The address for which to enable or disable bank operator privileges.
   * @param  _approved  True if approved, false if disapproved.
   */
  function setBankOperator(address _operator, bool _approved) external;

  /**
   * @notice Updates the Guardian contract allowed to toggle withdrawals.
   */
  function setGuardianContract(address _guardian) external;

  /**
   * @notice Get the bank balance of an account.
   * @param  _account  The address of the account to query the balances of.
   */
  function getAccountBankBalance(
    address _account
  ) external view returns (uint128);

  /**
   * @notice Updates the bank-wide withdrawal status
   * @dev Must be called by the Guardian
   * @param _newStatus withdrawal status for every account in every market. If not allowed then
   * funds cannot be withdrawn from MarginBank
   */
  function setWithdrawalStatus(Types.GuardianStatus _newStatus) external;

  /**
   * @notice Sets direct withdrawal request delay.
   * @dev The delay must be between one hour and seven days, inclusive. A change
   * affects requests created afterward; existing requests retain their recorded
   * executable timestamp.
   * @param _delaySeconds Delay in seconds between request and execution.
   */
  function setDirectWithdrawalDelaySeconds(uint64 _delaySeconds) external;

  /**
   * @notice Sets how long a direct withdrawal stays executable after its delay.
   * @dev The window must be between one day and thirty days, inclusive. A
   * change affects requests created afterward only; every existing request
   * keeps the `expiresAt` recorded when it was created.
   * @param _windowSeconds Seconds a matured request remains executable.
   */
  function setDirectWithdrawalExecutionWindowSeconds(
    uint64 _windowSeconds
  ) external;

  /**
   * @notice Sets the fee charged on relayed user withdrawals.
   * @param _feeRecipient Wallet receiving the fee in collateral tokens.
   * @param _feeAmount Flat fee in 18-decimal raw USDM units.
   */
  function setWithdrawalFeeConfig(
    address _feeRecipient,
    uint128 _feeAmount
  ) external;

  /**
   * @notice Quotes the fee and destination amount for a gross relayed withdrawal.
   */
  function quoteRelayedWithdrawal(
    uint128 _amount
  ) external view returns (uint128 feeAmount, uint128 amountOut);

  /**
   * @notice Adds or removes an address allowed to submit signature withdrawals.
   */
  function setWithdrawalRelayer(address _relayer, bool _approved) external;

  /**
   * @notice Sets the SignatureVerifier used for relayed withdrawal authorization.
   * @param _signatureVerifier Stateless verifier contract address.
   */
  function setSignatureVerifier(address _signatureVerifier) external;

  /**
   * Returns true if withdrawal is allowed from MarginBank else returns false
   */
  function isWithdrawalAllowed() external view returns (bool);
}
