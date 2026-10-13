// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// oz
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

// utils
import {BaseRelayRecipient} from './utils/BaseRelayRecipient.sol';
import {BlockContext} from './utils/BlockContext.sol';

// interfaces
import {IMarginBank} from './interfaces/IMarginBank.sol';
import {ISignatureVerifier} from './interfaces/ISignatureVerifier.sol';
import {ISystemAccountHolder} from './interfaces/ISystemAccountHolder.sol';

// libraries
import {Types} from './libraries/Types.sol';
import {Require} from './libraries/Require.sol';
import {TypedSignature} from './libraries/TypedSignature.sol';

/**
 * @title Margin Bank
 * @author MNX Markets <help@mnx.fi>
 * @notice Controls all the funds in perpetual protocol. Users must lock in their margin into margin bank
 * before it can be used to open any position on any perpetual market.
 * @dev When trades are executed to open/close position, the margin always remain in margin bank, just exchanges
 * address from one account to another. The accounts must withdraw margin to move it out of margin bank
 * The contract is made upgradable using openzeppelin upgrades-pluging, don't change
 * the order of variables. Read more: https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies
 */
contract MarginBank is
  IMarginBank,
  Ownable2StepUpgradeable,
  // OZ 5.6.1 is @custom:stateless and uses a fixed namespaced slot;
  // issue #32 tests pin these proxy-layout assumptions.
  ReentrancyGuard,
  BaseRelayRecipient,
  BlockContext
{
  uint8 private constant USDM_DECIMALS = 18;
  uint128 public constant DEFAULT_EXTERNAL_DEPOSIT_CAP = 100 * 10 ** 18;
  /// @notice Minimum delay between a direct withdrawal request and execution.
  uint64 public constant MIN_DIRECT_WITHDRAWAL_DELAY_SECONDS = 1 hours;
  /// @notice Maximum delay the owner may configure for direct withdrawals.
  uint64 public constant MAX_DIRECT_WITHDRAWAL_DELAY_SECONDS = 7 days;
  /// @notice Minimum execution window the owner may configure for direct withdrawals.
  /// @dev Deliberately a full day rather than an hour. The direct path is the
  /// non-custodial escape hatch, and a floor this low would let an owner shrink
  /// every user's window to the point where ordinary unavailability — a chain
  /// incident, a weekend, or a repeated Guardian pause timed across the window —
  /// reliably kills matured requests. A 24-hour floor keeps the expiry bounded
  /// (the point of audit #63) without making the escape hatch easy to squeeze.
  uint64 public constant MIN_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS =
    24 hours;
  /// @notice Maximum execution window the owner may configure for direct withdrawals.
  uint64 public constant MAX_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS =
    30 days;
  /// @notice Hard safety cap for the flat relayed-withdrawal fee: 1 USDM.
  uint128 public constant MAX_WITHDRAWAL_FEE_AMOUNT = 1_000_000_000_000_000_000;
  //
  // EVENTS
  //

  /// @notice event emitted when a change in user balance occurs in margin bank, except through
  /// `transferMarginToAccountSilent`, which emits nothing
  /// @dev DEPOST action implies deposit of funds to margin bank
  /// @dev WITHDRAW action implies funds are withdrawn from margin bank by an account
  /// @dev INTERNAL action implies funds are moved from one account to another by a bank operator
  /// (`transferMarginToAccount`) or by a system-account controller between its own accounts
  /// (`transferFromSystemAccount`)
  event BankBalanceUpdate(
    Action action,
    address indexed srcAddress,
    address indexed destAddress,
    uint128 amount,
    uint128 srcBalance,
    uint128 destBalance,
    uint128 timestamp
  );

  /// @notice Never emitted by this implementation; declared only. Moving bank funds into a
  /// Perpetual position emits `BankBalanceUpdate` (INTERNAL) via `transferMarginToAccount`,
  /// or no event via `transferMarginToAccountSilent`.
  event BankTransferToPerpetual(
    address indexed account,
    address destination,
    uint128 amount,
    uint128 balance,
    uint128 timestamp
  );
  /// @notice event emitted when a bank operator is added or removed
  event MarginBankOperatorUpdate(address operator, bool approved);
  event WithdrawalAuthConfigUpdate(address signatureVerifier);
  event WithdrawalRelayerUpdate(address indexed relayer, bool approved);
  event WithdrawalFeeConfigUpdate(
    address indexed feeRecipient,
    uint128 feeAmount
  );
  event WithdrawalFeeCharged(
    address indexed owner,
    address indexed destination,
    address indexed feeRecipient,
    uint128 grossAmount,
    uint128 feeAmount,
    uint128 amountOut
  );
  event GuardianContractUpdate(
    address indexed previousGuardian,
    address indexed newGuardian
  );
  event WithdrawalStatusUpdate(
    Types.GuardianStatus previousStatus,
    Types.GuardianStatus newStatus
  );
  event DirectWithdrawalDelayUpdate(uint64 delaySeconds);
  event DirectWithdrawalExecutionWindowUpdate(uint64 windowSeconds);
  /// @notice A direct withdrawal request and its full lifecycle schedule.
  /// @dev `requestedAt` and `expiresAt` were added by the expiry upgrade (audit
  /// #63), which changes this event's topic hash. That is a deliberate clean
  /// cutover: the upgrade requires every historical request to be executed or
  /// cancelled, so no old-format log represents a live right after the swap.
  /// Consumers derive the new topic from this ABI rather than hardcoding it.
  ///
  /// `requestedAt` is carried explicitly rather than derived: `executableAt`
  /// minus the delay is not recoverable once the owner changes the configured
  /// delay, and reading it from the block timestamp costs every consumer an
  /// extra lookup.
  event DirectWithdrawalRequested(
    address indexed owner,
    address indexed destination,
    uint128 amount,
    uint128 requestId,
    uint64 requestedAt,
    uint64 executableAt,
    uint64 expiresAt
  );
  /// @notice Emitted by `initialize` on a fresh deployment, and by the one-time expiry
  /// migration (`initializeDirectWithdrawalExpiry`) on an upgraded proxy.
  event DirectWithdrawalExpiryInitialized(uint64 executionWindowSeconds);
  event DirectWithdrawalExecuted(
    address indexed owner,
    address indexed destination,
    uint128 amount,
    uint128 requestId,
    uint128 ownerBalance
  );
  event DirectWithdrawalCancelled(address indexed owner, uint128 requestId);
  event RelayedWithdrawalExecuted(
    address indexed owner,
    address indexed destination,
    uint128 amount,
    uint128 nonce,
    uint128 ownerBalance
  );
  /// @notice A system account was registered and permanently bound to a controller.
  event SystemAccountRegistered(
    address indexed account,
    address indexed controller
  );
  /// @notice The owner allowed or revoked a system-account controller.
  event ApprovedControllerUpdate(address indexed controller, bool approved);
  /// @notice Emitted once when the #70 binding migration runs on an upgraded proxy.
  /// @dev `inventoryChecksum` is the digest of the reviewed, fixed-block account
  /// inventory the campaign migrated from, so the on-chain record names the exact
  /// artifact a reviewer can re-derive.
  /// @dev One count, not two: an approval is only ever created here by carrying
  ///      a revoked deprecated one forward, so an "approved controller count"
  ///      could never differ from the revoked count.
  event SystemAccountBindingsInitialized(
    uint256 accountCount,
    uint256 revokedDeprecatedControllerCount,
    bytes32 inventoryChecksum
  );
  /// @notice A deprecated protocol-wide controller approval was cleared.
  event DeprecatedSystemAccountControllerRevoked(address indexed controller);
  event ExternalDepositCapUpdate(uint128 cap);
  event ExternalDepositCapExemptAccountUpdate(
    address indexed account,
    bool exempt
  );

  //
  // ENUMS
  //
  enum Action {
    DEPOSIT,
    WITHDRAW,
    INTERNAL
  }

  //**********************************************************//
  //    The below state variables can not change the order    //
  //**********************************************************//

  /// @notice address of the erc20 margin token used to collateralize positions
  address public token;

  /// @notice mapping of addresses allowed to move funds on behalf of accounts.
  /// @dev Set only by the owner via `setBankOperator`, which checks only that an
  /// approved address has code. In this repository only `Perpetual` calls the
  /// operator functions.
  mapping(address => bool) public bankOperators;

  /// @notice mapping between account and available margin bank balance
  /// @dev margin amount is stored in 18 decimals
  mapping(address => uint128) public bankBalances;

  /// @notice address of the guardian contract
  address public guardianContract;

  /// @notice status of the withdrawal as set by the Guardian
  Types.GuardianStatus private withdrawalStatus;

  uint256[50] private __gap;

  //**********************************************************//
  //    The above state variables can not change the order    //
  //**********************************************************//

  //◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤ add state variables below ◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤//

  uint64 public directWithdrawalDelaySeconds;
  uint128 public nextDirectWithdrawalRequestId;
  address public signatureVerifier;
  mapping(address => uint128) public nextWithdrawalNonce;
  mapping(uint128 => DirectWithdrawalRequest) public directWithdrawalRequests;
  /// @notice The owner's most recent unexecuted, uncancelled request id, or zero.
  /// @dev A non-zero value does NOT imply the request still blocks anything.
  /// Expiry does not clear this slot, and past its deadline a request blocks
  /// neither withdrawal path; it is retired only when the owner executes,
  /// cancels, or supersedes it with a new request. Read
  /// `directWithdrawalExpiryAt(requestId)` to tell live from expired.
  mapping(address => uint128) public activeDirectWithdrawalRequestByOwner;
  mapping(address => bool) public systemAccounts;

  /// @notice DEPRECATED (audit #70). Protocol-wide controller approvals.
  /// @dev No authorization path reads this mapping any more — authority comes
  /// from `controllerOf` plus `isApprovedController`. The slot is kept, and must
  /// never be reused, so the layout of every live proxy stays valid and so the
  /// migration campaign can prove the old approvals were revoked. There is no
  /// setter left; `initializeSystemAccountBindings` clears the entries the
  /// reviewed inventory found.
  mapping(address => bool) public systemAccountControllers;

  /// @notice Per-account cap on fresh external deposits net of withdrawals.
  /// @dev Trading profit/loss and internal transfers do not change this cap
  /// usage. It is not a cap on balance, retained principal, or account
  /// exposure.
  uint128 public externalDepositCap;

  /// @notice External deposits minus external withdrawals for each account.
  /// @dev Withdrawals restore fresh-deposit capacity. Trading profit/loss and
  /// internal transfers intentionally do not change this value.
  mapping(address => uint128) public netExternalDeposits;
  mapping(address => bool) public externalDepositCapExemptAccounts;
  uint256 public totalBankLiabilities;
  mapping(address => bool) public withdrawalRelayers;
  address public withdrawalFeeRecipient;
  uint128 public withdrawalFeeAmount;

  /// @notice How long a direct withdrawal stays executable once its delay elapses.
  /// @dev Recorded into each new request as an immutable `expiresAt`. Changing
  /// this value never rewrites an existing request.
  uint64 public directWithdrawalExecutionWindowSeconds;

  /// @notice The single controller each system account is bound to (audit #70).
  /// @dev Append-only: a binding is written once, by the registration that
  /// checked the account is a contract whose `controller()` returns the
  /// registering caller, or by the one-time migration for
  /// accounts that predate the binding. Nothing rewrites or clears it. A
  /// controller has authority only over accounts bound to it here, and only while
  /// `isApprovedController` approves it — approving a controller grants it
  /// nothing over accounts not bound to it.
  mapping(address => address) public controllerOf;

  /// @notice Contracts the owner allows to register and control system accounts.
  /// @dev Checked together with `controllerOf`, never instead of it. It exists
  /// so the owner can (a) decide who may create system accounts at all, and
  /// (b) revoke a compromised controller — bindings are append-only, so this is
  /// the only lever that can stop one.
  mapping(address => bool) public isApprovedController;

  /// @notice True once controller registration and the controller money paths are
  /// open.
  /// @dev Set by `initialize` for fresh deployments (which have no accounts yet)
  /// and by `initializeSystemAccountBindings` for upgraded proxies. Controller
  /// registration and every controller money path is gated on it, so an upgraded
  /// proxy whose bindings were never populated fails closed instead of
  /// authorizing against an empty mapping.
  bool public systemAccountBindingsMigrated;

  //◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣ add state variables above ◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣//

  /**
   * @dev Throws if the caller is not an approved bank operator. `_msgSender()`
   * is not overridden here, so this reads the raw `msg.sender`.
   */
  modifier onlyBankOPerators() {
    require(
      bankOperators[_msgSender()],
      'MarginBank: caller is not a bank operator'
    );
    _;
  }

  /// @dev Controller authority deliberately reads `msg.sender`, not the
  /// forwarder-aware `msgSender()`. Controllers are contracts that call this
  /// bank directly; no controller path is ever relayed. Reading the raw caller
  /// keeps a misconfigured or malicious trusted forwarder out of the
  /// system-account money paths entirely.
  modifier onlyAccountController(address _systemAccount) {
    _requireSystemAccountBindingsMigrated();
    _requireAccountController(_systemAccount);
    _;
  }

  /**
   * Throws if called by any account other than the guardian
   */
  modifier onlyGuardianContract() {
    require(
      guardianContract == _msgSender(),
      'MarginBank: caller is not the guardian contract'
    );
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice initializes the contract
   * @param  _token  address of the token to use for margin-deposits
   * @param  _guardian address of the guardian contract
   * @param  _trustedForwarder The ERC-2771 forwarder contract whose appended sender
   *         `msgSender()` trusts; it must have deployed code
   * @param  _signatureVerifier Stateless contract used to verify relayed withdrawals
   * @param  _directWithdrawalExecutionWindowSeconds How long a matured direct
   *         withdrawal stays executable. There is no default: every deployment
   *         must state this value explicitly.
   */
  function initialize(
    address _token,
    address _guardian,
    address _trustedForwarder,
    address _signatureVerifier,
    uint64 _directWithdrawalExecutionWindowSeconds
  ) public initializer {
    token = _token;
    require(
      IERC20Metadata(_token).decimals() == USDM_DECIMALS,
      'MarginBank: collateral must have 18 decimals'
    );
    require(
      _signatureVerifier != address(0),
      'MarginBank: invalid signature verifier'
    );
    require(_guardian != address(0), 'MarginBank: invalid guardian');
    guardianContract = _guardian;
    signatureVerifier = _signatureVerifier;
    directWithdrawalDelaySeconds = MIN_DIRECT_WITHDRAWAL_DELAY_SECONDS;
    nextDirectWithdrawalRequestId = 1;
    externalDepositCap = DEFAULT_EXTERNAL_DEPOSIT_CAP;
    // A fresh bank has no system accounts, so there is nothing to migrate and
    // controller registration is open from the start.
    systemAccountBindingsMigrated = true;
    _initializeDirectWithdrawalExpiry(_directWithdrawalExecutionWindowSeconds);

    __MetaTransaction_init(_trustedForwarder);
    __Ownable_init(_msgSender());
    __Ownable2Step_init();
    emit WithdrawalAuthConfigUpdate(_signatureVerifier);
  }

  /**
   * @notice Records direct-withdrawal expiry configuration on a proxy upgraded
   *         from an implementation that predates per-request expiry.
   * @dev Runs exactly once, as reinitializer version 2. Both the live testnet and
   *      mainnet MarginBank proxies read `_initialized == 1` before this upgrade,
   *      so 2 is the next unused version. It must run in the same transaction
   *      as the upgrade (`ProxyAdmin.upgradeAndCall`), which is why the ERC-1967
   *      proxy admin is accepted alongside the owner: during `upgradeAndCall` the
   *      delegatecall into this implementation sees the ProxyAdmin as `msg.sender`.
   *
   *      This is an intentionally clean cutover: it reverts unless every
   *      historical direct-withdrawal request is terminal (executed or
   *      cancelled). Deployment tooling performs the same scan before
   *      submitting upgradeAndCall, while this on-chain check makes the
   *      no-outstanding-request requirement atomic and unskippable.
   * @param _executionWindowSeconds How long a matured direct withdrawal stays executable.
   */
  function initializeDirectWithdrawalExpiry(
    uint64 _executionWindowSeconds
  ) external reinitializer(2) {
    require(
      msg.sender == owner() || msg.sender == ERC1967Utils.getAdmin(),
      'MarginBank: caller cannot initialize expiry'
    );
    _requireNoOutstandingDirectWithdrawalRequests();
    _initializeDirectWithdrawalExpiry(_executionWindowSeconds);
  }

  /**
   * @notice Binds every system account that predates per-controller isolation
   *         to the controller that owns it (audit issue #70).
   * @dev Runs exactly once, as reinitializer version 3. Version 2 is
   *      `initializeDirectWithdrawalExpiry`, so 3 is the next unused version;
   *      the campaign refuses to run until version 2 has been applied, because
   *      a jump straight to 3 would permanently lock the expiry migration out.
   *
   *      It must run in the same transaction as the upgrade
   *      (`ProxyAdmin.upgradeAndCall`), which is why the ERC-1967 proxy admin is
   *      accepted alongside the owner: during `upgradeAndCall` the delegatecall
   *      into this implementation sees the ProxyAdmin as `msg.sender`. Atomicity
   *      matters here — between a bare upgrade and this call every controller
   *      money path reverts, so the vault could neither pay an LP nor fund a
   *      child.
   *
   *      Every pair is re-proved on-chain against the same holder shape a live
   *      registration must satisfy, so a malformed, duplicated, or mismatched
   *      inventory reverts the whole upgrade instead of writing a wrong binding.
   *      The reviewed fixed-block inventory's digest is recorded here, and the
   *      campaign checks it before and after the upgrade.
   * @param _accounts Every existing system account, from the reviewed inventory.
   * @param _controllers The controller of each account, positionally paired.
   * @param _deprecatedControllersToRevoke Addresses still holding a deprecated
   *        protocol-wide approval, cleared here. Only the addresses passed are
   *        cleared, so this does not guarantee the mapping is empty afterwards:
   *        an approval granted between the inventory block and this call keeps
   *        its stale `true` forever, since no setter for it survives the
   *        upgrade. That residue is inert — no authorization path reads the
   *        deprecated mapping — and the campaign's preflight is what makes the
   *        list complete in practice.
   * @param _inventoryChecksum Digest of the reviewed inventory artifact.
   */
  function initializeSystemAccountBindings(
    address[] calldata _accounts,
    address[] calldata _controllers,
    address[] calldata _deprecatedControllersToRevoke,
    bytes32 _inventoryChecksum
  ) external reinitializer(3) {
    require(
      msg.sender == owner() || msg.sender == ERC1967Utils.getAdmin(),
      'MarginBank: caller cannot initialize bindings'
    );
    // #63 first: reinitializer 3 would permanently lock reinitializer 2 out.
    // The expiry cutover's own initialization signal is the configured window
    // being in range, which is what this helper checks — the shared legacy
    // deadline it used to be read from was removed when that cutover was
    // finalized.
    _requireDirectWithdrawalExpiryInitialized();
    require(
      _accounts.length == _controllers.length,
      'MarginBank: binding length mismatch'
    );
    // An empty set is deliberately allowed: an environment whose vault was
    // deployed but never bootstrapped has no accounts, and refusing it here
    // would leave that environment unable to migrate at all. Its controller
    // still carries its approval forward below, so bootstrap works afterwards.
    // The campaign refuses an empty inventory unless the operator confirms it
    // and no system account is registered at all.
    require(
      _inventoryChecksum != bytes32(0),
      'MarginBank: invalid inventory checksum'
    );

    // Binding and approval are separate decisions, deliberately.
    //
    // Binding is a statement of fact — this holder's immutable controller() is
    // that address — so it is written for every inventory entry unconditionally.
    // Withdrawals from a system account go only through its bound controller,
    // so binding must never be withheld.
    //
    // Approval is a statement of current intent, and only the owner holds it.
    // It is therefore carried forward from what the owner approves *right now*
    // (the loop below), never inferred from an inventory entry. Otherwise an
    // owner who revoked a compromised controller after the inventory was built
    // would have that revocation silently undone here.
    for (uint256 i = 0; i < _accounts.length; i++) {
      address account = _accounts[i];
      address controller = _controllers[i];
      require(
        systemAccounts[account],
        'MarginBank: inventory account is not a system account'
      );
      require(
        controllerOf[account] == address(0),
        'MarginBank: duplicate inventory account'
      );
      _requireHolderControlledBy(account, controller);

      controllerOf[account] = controller;
      emit SystemAccountRegistered(account, controller);
    }

    // Carry each still-live protocol-wide approval into the new mapping and
    // clear the old one, atomically. Skipping an entry that is already clear —
    // rather than reverting — matters because a revocation landing between the
    // inventory build and this transaction must not take the whole
    // upgrade-and-call down with it. It is also exactly what makes such a
    // revocation stick: a controller the owner already revoked is simply not
    // carried forward.
    uint256 revokedControllerCount = 0;
    for (uint256 i = 0; i < _deprecatedControllersToRevoke.length; i++) {
      address deprecatedController = _deprecatedControllersToRevoke[i];
      if (!systemAccountControllers[deprecatedController]) continue;

      // Same requirement setApprovedController enforces.
      require(
        deprecatedController.code.length > 0,
        'MarginBank: controller not contract'
      );
      systemAccountControllers[deprecatedController] = false;
      isApprovedController[deprecatedController] = true;
      revokedControllerCount += 1;
      emit DeprecatedSystemAccountControllerRevoked(deprecatedController);
      emit ApprovedControllerUpdate(deprecatedController, true);
    }

    systemAccountBindingsMigrated = true;
    emit SystemAccountBindingsInitialized(
      _accounts.length,
      revokedControllerCount,
      _inventoryChecksum
    );
  }

  function setTrustedForwarder(address _trustedForwarder) external onlyOwner {
    _setTrustedForwarder(_trustedForwarder);
  }

  //===========================================================//
  //                         SETTERS
  //===========================================================//

  /**
   * @notice Add or remove a Bank Operator address.
   * @dev Must be called by the owner.
   * @param  _operator  The address for which to enable or disable bank operator privileges.
   * @param  _approved  True if approved, false if disapproved.
   */
  function setBankOperator(
    address _operator,
    bool _approved
  ) external override onlyOwner nonReentrant {
    require(_operator != address(0), 'MarginBank: invalid operator');
    // Operator contracts do not implement ERC-165; owner-gated code existence plus events is the control.
    if (_approved) {
      require(_operator.code.length > 0, 'MarginBank: operator not contract');
    }
    bankOperators[_operator] = _approved;

    emit MarginBankOperatorUpdate(_operator, _approved);
  }

  /**
   * @notice Updates the guardian contract allowed to toggle withdrawal status.
   * @param _guardian Non-zero guardian contract address.
   */
  function setGuardianContract(
    address _guardian
  ) external override onlyOwner nonReentrant {
    require(_guardian != address(0), 'MarginBank: invalid guardian');
    address previousGuardian = guardianContract;
    guardianContract = _guardian;
    emit GuardianContractUpdate(previousGuardian, _guardian);
  }

  /**
   * @notice Updates the bank-wide withdrawal status
   * @param _newStatus withdrawal status for every account in every market. If not
   * allowed then funds cannot be withdrawn from the MarginBank
   */
  function setWithdrawalStatus(
    Types.GuardianStatus _newStatus
  ) external override nonReentrant onlyGuardianContract {
    Types.GuardianStatus previousStatus = withdrawalStatus;
    withdrawalStatus = _newStatus;
    emit WithdrawalStatusUpdate(previousStatus, _newStatus);
  }

  /**
   * @notice Sets the direct withdrawal request delay.
   * @dev The delay must be between one hour and seven days, inclusive. A change
   *      affects requests created afterward; existing requests retain their
   *      recorded executable timestamp.
   * @param _delaySeconds Delay in seconds between request and execution.
   */
  function setDirectWithdrawalDelaySeconds(
    uint64 _delaySeconds
  ) external override onlyOwner nonReentrant {
    require(
      _delaySeconds >= MIN_DIRECT_WITHDRAWAL_DELAY_SECONDS &&
        _delaySeconds <= MAX_DIRECT_WITHDRAWAL_DELAY_SECONDS,
      'MarginBank: delay out of range'
    );
    directWithdrawalDelaySeconds = _delaySeconds;
    emit DirectWithdrawalDelayUpdate(_delaySeconds);
  }

  /**
   * @notice Sets how long a direct withdrawal stays executable after its delay.
   * @dev The window must be between one day and thirty days, inclusive. It is
   *      applied when a request is created and copied into that request, so a
   *      change here can neither shorten nor extend an already-created request.
   * @param _windowSeconds Seconds a matured request remains executable.
   */
  function setDirectWithdrawalExecutionWindowSeconds(
    uint64 _windowSeconds
  ) external override onlyOwner nonReentrant {
    _requireDirectWithdrawalExpiryInitialized();
    _requireDirectWithdrawalExecutionWindowInRange(_windowSeconds);
    directWithdrawalExecutionWindowSeconds = _windowSeconds;
    emit DirectWithdrawalExecutionWindowUpdate(_windowSeconds);
  }

  /**
   * @notice Sets the fee charged on relayed user withdrawals.
   * @dev Delayed direct withdrawals remain fee-free.
   */
  function setWithdrawalFeeConfig(
    address _feeRecipient,
    uint128 _feeAmount
  ) external override onlyOwner nonReentrant {
    require(_feeRecipient != address(0), 'MarginBank: invalid fee recipient');
    require(
      _feeRecipient != address(this) && _feeRecipient != token,
      'MarginBank: invalid fee recipient'
    );
    require(
      _feeAmount <= MAX_WITHDRAWAL_FEE_AMOUNT,
      'MarginBank: withdrawal fee too high'
    );
    withdrawalFeeRecipient = _feeRecipient;
    withdrawalFeeAmount = _feeAmount;
    emit WithdrawalFeeConfigUpdate(_feeRecipient, _feeAmount);
  }

  function quoteRelayedWithdrawal(
    uint128 _amount
  ) external view override returns (uint128 feeAmount, uint128 amountOut) {
    return _quoteRelayedWithdrawal(_amount);
  }

  /**
   * @notice Adds or removes a relayer that may submit instant signature withdrawals.
   * @param _relayer Actual transaction submitter address to update.
   * @param _approved True to allow, false to remove.
   */
  function setWithdrawalRelayer(
    address _relayer,
    bool _approved
  ) external override onlyOwner nonReentrant {
    require(_relayer != address(0), 'MarginBank: invalid withdrawal relayer');
    withdrawalRelayers[_relayer] = _approved;
    emit WithdrawalRelayerUpdate(_relayer, _approved);
  }

  /**
   * @notice Updates the verifier used for relayed withdrawal authorization.
   * @param _signatureVerifier Stateless contract used to verify withdrawal signatures.
   */
  function setSignatureVerifier(
    address _signatureVerifier
  ) external override onlyOwner nonReentrant {
    require(
      _signatureVerifier != address(0),
      'MarginBank: invalid signature verifier'
    );
    signatureVerifier = _signatureVerifier;
    emit WithdrawalAuthConfigUpdate(_signatureVerifier);
  }

  /**
   * @notice Registers a system account and binds it to the calling controller.
   * @dev The caller must be an owner-approved controller, and `_account` must be
   * a contract whose `controller()` returns that same caller. Those two
   * conditions stop a controller from registering an ordinary user or another
   * controller's holder and gaining withdrawal or trading authority over it.
   * They do not prove the account runs `SystemAccountHolder` code or that its
   * `controller()` cannot change; see `_requireHolderControlledBy` for why that
   * gives a controller nothing a genuine holder would not.
   *
   * There is no unregister: the binding is append-only, and a holder that has
   * been classified as a system account stays one. Nothing needs to reverse it,
   * and a reversible flag would let the classification be dropped to route a
   * vault-owned balance back through the ordinary user withdrawal paths.
   */
  function registerSystemAccount(
    address _account
  ) external override nonReentrant {
    _requireSystemAccountBindingsMigrated();
    require(
      isApprovedController[msg.sender],
      'MarginBank: caller is not an approved controller'
    );
    require(_account != address(0), 'MarginBank: invalid system account');
    require(
      controllerOf[_account] == address(0),
      'MarginBank: system account already bound'
    );
    _requireHolderControlledBy(_account, msg.sender);

    controllerOf[_account] = msg.sender;
    systemAccounts[_account] = true;
    emit SystemAccountRegistered(_account, msg.sender);
  }

  /**
   * @notice Allows or revokes a contract's ability to control system accounts.
   * @dev Approval alone grants authority over nothing: every money path also
   * requires the account to be bound to the caller. Revoking is the only way to
   * stop a compromised controller, because bindings are append-only.
   */
  function setApprovedController(
    address _controller,
    bool _approved
  ) external override onlyOwner nonReentrant {
    require(_controller != address(0), 'MarginBank: invalid controller');
    // A controller has to be able to be a SystemAccountHolder's controller and
    // call this bank; owner-gated code existence plus events is the control, the
    // same shape setBankOperator uses.
    if (_approved) {
      require(
        _controller.code.length > 0,
        'MarginBank: controller not contract'
      );
    }
    isApprovedController[_controller] = _approved;
    emit ApprovedControllerUpdate(_controller, _approved);
  }

  function setExternalDepositCap(
    uint128 _cap
  ) external override onlyOwner nonReentrant {
    externalDepositCap = _cap;
    emit ExternalDepositCapUpdate(_cap);
  }

  function setExternalDepositCapExemptAccounts(
    address[] calldata _accounts,
    bool _exempt
  ) external override onlyOwner nonReentrant {
    for (uint256 i = 0; i < _accounts.length; i++) {
      address account = _accounts[i];
      require(account != address(0), 'MarginBank: invalid account');
      externalDepositCapExemptAccounts[account] = _exempt;
      emit ExternalDepositCapExemptAccountUpdate(account, _exempt);
    }
  }

  /**
   * @notice Deposits collateral token from caller's address to provided
   * account address in margin bank.
   * @dev the caller must approve margin bank to take funds on their behalf
   * from collateral token before invoking this method
   * @dev amount is expected to be in the collateral token's own raw units
   * @param  _account receiver account address
   * @param  _amount amount of tokens to be deposited
   * @return true if deposit successful.
   */
  function depositToBank(
    address _account,
    uint128 _amount
  ) external override nonReentrant returns (bool) {
    address caller = msgSender();
    _depositFrom(caller, _account, _amount);
    return true;
  }

  /**
   * @notice Deposits collateral using an EIP-2612 permit instead of a separate approve transaction.
   * @dev Gasless deposits must be relayed through the ERC-2771 trusted forwarder.
   *      The permit owner is deliberately bound to msgSender() so the same signed
   *      calldata authenticates the token owner and destination account; a bare
   *      permit authorizes an amount, but not the `_account` receiving credit.
   *      Amount is expected to be in 18-decimal USDM raw units.
   * @param _account receiver account address
   * @param _amount amount of tokens to be deposited
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
  ) external override nonReentrant returns (bool) {
    address caller = msgSender();

    try
      IERC20Permit(token).permit(
        caller,
        address(this),
        _amount,
        _deadline,
        _v,
        _r,
        _s
      )
    {} catch {
      require(
        IERC20(token).allowance(caller, address(this)) >= _amount,
        'MarginBank: permit failed'
      );
    }
    _depositFrom(caller, _account, _amount);
    return true;
  }

  /**
   * @notice Deposits the caller's full approved amount into the provided account.
   * @dev Intended for exact-allowance routed contract-call flows, such as the
   *      Daimo Pay router. Infinite approvals are unsupported here; callers with
   *      standing approvals should use depositToBank with an explicit amount.
   * @param _account receiver account address
   * @return true if deposit successful.
   */
  function depositFullAllowanceToBank(
    address _account
  ) external override nonReentrant returns (bool) {
    address caller = msgSender();
    uint256 approvedAmount = IERC20(token).allowance(caller, address(this));
    require(approvedAmount > 0, 'MarginBank: no allowance');
    require(
      approvedAmount <= type(uint128).max,
      'MarginBank: infinite allowance unsupported, use depositToBank'
    );

    _depositFrom(caller, _account, uint128(approvedAmount));
    return true;
  }

  /**
   * @notice Deposits collateral token from caller's address to multiple provided
   * account addresses in margin bank.
   * @dev the caller must approve margin bank to take funds on their behalf
   * from collateral token before invoking this method
   * @dev amount is expected to be in the collateral token's own raw units
   * @param _accounts receiver account addresses
   * @param _amount amount of tokens to be deposited per account
   * @return true if deposit successful.
   */
  function depositToBankBatch(
    address[] calldata _accounts,
    uint128 _amount
  ) external override nonReentrant returns (bool) {
    require(_accounts.length > 0, 'MarginBank: empty account batch');

    // gas less transaction, decode sender address
    address caller = msgSender();
    uint256 totalAmount = uint256(_amount) * _accounts.length;
    uint128 callerBalance = bankBalances[caller];
    uint128 timestamp = _blockTimestamp();

    for (uint256 i = 0; i < _accounts.length; i++) {
      _recordExternalDeposit(_accounts[i], _amount);
    }

    // transfer total amount from caller to margin bank once
    /// @dev will revert if caller does not have enough funds
    SafeERC20.safeTransferFrom(
      IERC20(token),
      caller,
      address(this),
      totalAmount
    );

    for (uint256 i = 0; i < _accounts.length; i++) {
      address account = _accounts[i];
      bankBalances[account] += _amount;

      emit BankBalanceUpdate(
        Action.DEPOSIT,
        caller,
        account,
        _amount,
        callerBalance,
        bankBalances[account],
        timestamp
      );
    }
    _increaseBankLiabilities(totalAmount);
    _requireSufficientCollateral();

    return true;
  }

  /**
   * @notice Requests a fee-free delayed direct withdrawal of margin tokens.
   * @param  _destination Destination address to receive the transferred tokens
   * @param  _amount Collateral amount debited and transferred, in token raw units
   * @return requestId Created withdrawal request id
   */
  function requestWithdrawFromBank(
    address _destination,
    uint128 _amount
  ) external override nonReentrant returns (uint128 requestId) {
    require(
      !systemAccounts[msgSender()],
      'MarginBank: system account withdrawal'
    );
    return _requestWithdrawFromBank(msgSender(), _destination, _amount);
  }

  /**
   * @notice Executes a delayed direct withdrawal after the delay elapsed.
   * @param _requestId Withdrawal request id
   */
  function executeWithdrawFromBank(
    uint128 _requestId
  ) external override nonReentrant {
    DirectWithdrawalRequest storage request = directWithdrawalRequests[
      _requestId
    ];
    address caller = msgSender();

    require(request.owner != address(0), 'MarginBank: unknown withdrawal');
    require(caller == request.owner, 'MarginBank: caller is not owner');
    require(!request.executed, 'MarginBank: withdrawal already executed');
    require(!request.cancelled, 'MarginBank: withdrawal cancelled');
    _requireDirectWithdrawalExpiryInitialized();
    require(
      block.timestamp >= request.executableAt,
      'MarginBank: withdrawal delay active'
    );
    // Inclusive upper bound: execution at exactly the deadline still succeeds.
    require(
      block.timestamp <= request.expiresAt,
      'MarginBank: withdrawal expired'
    );

    request.executed = true;
    if (activeDirectWithdrawalRequestByOwner[request.owner] == _requestId) {
      activeDirectWithdrawalRequestByOwner[request.owner] = 0;
    }
    uint128 ownerBalance = _executeWithdrawal(
      request.owner,
      request.destination,
      request.amount,
      0
    );

    emit DirectWithdrawalExecuted(
      request.owner,
      request.destination,
      request.amount,
      _requestId,
      ownerBalance
    );
  }

  /**
   * @notice Last timestamp at which a direct withdrawal request may execute.
   * @dev Zero for an unknown request id.
   * @param _requestId Withdrawal request id
   */
  function directWithdrawalExpiryAt(
    uint128 _requestId
  ) external view override returns (uint64) {
    DirectWithdrawalRequest storage request = directWithdrawalRequests[
      _requestId
    ];
    if (request.owner == address(0)) {
      return 0;
    }
    return request.expiresAt;
  }

  /**
   * @notice Cancels a delayed direct withdrawal request.
   * @dev Deliberately available after expiry, so the owner can always retire a
   *      request. A new request does not need it: `requestWithdrawFromBank`
   *      supersedes an expired request itself, and the new request serves the
   *      full delay again.
   * @param _requestId Withdrawal request id
   */
  function cancelWithdrawFromBank(
    uint128 _requestId
  ) external override nonReentrant {
    DirectWithdrawalRequest storage request = directWithdrawalRequests[
      _requestId
    ];
    address caller = msgSender();

    require(request.owner != address(0), 'MarginBank: unknown withdrawal');
    require(caller == request.owner, 'MarginBank: caller is not owner');
    require(!request.executed, 'MarginBank: withdrawal already executed');
    require(!request.cancelled, 'MarginBank: withdrawal cancelled');

    request.cancelled = true;
    // A stale request id must never clear a newer successor's active pointer.
    if (activeDirectWithdrawalRequestByOwner[request.owner] == _requestId) {
      activeDirectWithdrawalRequestByOwner[request.owner] = 0;
    }

    emit DirectWithdrawalCancelled(request.owner, _requestId);
  }

  /**
   * @notice Withdraws margin tokens on behalf of an owner using an EIP-712 signature.
   * @dev This is the instant relayed path: only owner-managed withdrawal relayers
   *      may submit the signed authorization, while users retain the permissionless
   *      timelocked request/execute direct path as the non-custodial escape hatch.
   *      Both paths are blocked while the Guardian has withdrawals paused.
   *      The relayer gate intentionally checks msg.sender, not msgSender(), so the
   *      allowlist binds the actual transaction submitter and cannot be satisfied
   *      through the trusted forwarder.
   * @param _owner Account whose MarginBank balance is reduced
   * @param _destination Destination address to receive the transferred tokens
   * @param _amount Number of collateral tokens to transfer, in token raw units
   * @param _minimumAmountOut Minimum tokens the destination must receive after fees
   * @param _nonce Current per-owner withdrawal nonce
   * @param _deadline Last timestamp at which the authorization is valid
   * @param _signature Owner signature over the withdrawal
   */
  function withdrawFromBankWithAuth(
    address _owner,
    address _destination,
    uint128 _amount,
    uint128 _minimumAmountOut,
    uint128 _nonce,
    uint64 _deadline,
    TypedSignature.Signature calldata _signature
  ) external override nonReentrant {
    require(signatureVerifier != address(0), 'MarginBank: auth not configured');
    require(
      withdrawalRelayers[msg.sender],
      'MarginBank: caller not withdrawal relayer'
    );
    require(!systemAccounts[_owner], 'MarginBank: system account withdrawal');
    require(block.timestamp <= _deadline, 'MarginBank: signature expired');
    require(_nonce == nextWithdrawalNonce[_owner], 'MarginBank: invalid nonce');
    require(
      _blockingDirectWithdrawalRequestId(_owner) == 0,
      'MarginBank: pending withdrawal exists'
    );

    address signer = ISignatureVerifier(signatureVerifier)
      .recoverWithdrawalSigner(
        address(this),
        _owner,
        _destination,
        _amount,
        _minimumAmountOut,
        _nonce,
        _deadline,
        _signature
      );
    // a zero signer means signature recovery failed; reject it explicitly so
    // a malformed signature can never authorize a zero-owner withdrawal
    require(
      signer != address(0) && _owner == signer,
      'MarginBank: invalid signer'
    );
    nextWithdrawalNonce[_owner] = _nonce + 1;

    (uint128 feeAmount, ) = _validatedWithdrawalQuote(
      _amount,
      _minimumAmountOut
    );
    uint128 ownerBalance = _executeWithdrawal(
      _owner,
      _destination,
      _amount,
      feeAmount
    );
    emit RelayedWithdrawalExecuted(
      _owner,
      _destination,
      _amount,
      _nonce,
      ownerBalance
    );
  }

  function depositStrandedSystemAccountToken(
    address _srcAddress,
    address _systemAccount,
    uint128 _amount
  )
    external
    override
    nonReentrant
    onlyAccountController(_systemAccount)
    returns (bool)
  {
    require(_srcAddress != address(0), 'MarginBank: invalid source');
    require(_amount > 0, 'MarginBank: invalid amount');

    bankBalances[_systemAccount] += _amount;
    _increaseBankLiabilities(_amount);
    _requireSufficientCollateral();

    emit BankBalanceUpdate(
      Action.DEPOSIT,
      _srcAddress,
      _systemAccount,
      _amount,
      bankBalances[_srcAddress],
      bankBalances[_systemAccount],
      _blockTimestamp()
    );
    return true;
  }

  /**
   * @notice Moves margin between two system accounts bound to the caller.
   * @dev Both sides must be the caller's own accounts. Cross-controller movement
   * is rejected rather than authorized: the only production flow is a
   * LiquidityVault moving liquidity between its own main and child accounts, so
   * an authorization mechanism for moving another controller's balance would be
   * a speculative capability with nothing using it.
   */
  function transferFromSystemAccount(
    address _systemAccount,
    address _destinationSystemAccount,
    uint128 _amount
  ) external override nonReentrant onlyAccountController(_systemAccount) {
    require(
      controllerOf[_destinationSystemAccount] == msg.sender,
      'MarginBank: destination not controlled by caller'
    );
    require(_amount > 0, 'MarginBank: invalid amount');
    Require.that(
      bankBalances[_systemAccount] >= _amount,
      'Insufficient account funds',
      _systemAccount
    );

    bankBalances[_systemAccount] -= _amount;
    bankBalances[_destinationSystemAccount] += _amount;

    emit BankBalanceUpdate(
      Action.INTERNAL,
      _systemAccount,
      _destinationSystemAccount,
      _amount,
      bankBalances[_systemAccount],
      bankBalances[_destinationSystemAccount],
      _blockTimestamp()
    );
  }

  function withdrawFromSystemAccount(
    address _systemAccount,
    address _destination,
    uint128 _amount
  ) external override nonReentrant onlyAccountController(_systemAccount) {
    _executeWithdrawalFromAccount(_systemAccount, _destination, _amount);
  }

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
  ) external override nonReentrant onlyBankOPerators {
    // Ensure account has enough funds for trade
    Require.that(
      bankBalances[_account] >= _amount,
      'Insufficient account funds',
      _account
    );

    bankBalances[_account] -= _amount;

    bankBalances[_destination] += _amount;

    emit BankBalanceUpdate(
      Action.INTERNAL,
      _account,
      _destination,
      _amount,
      bankBalances[_account],
      bankBalances[_destination],
      _blockTimestamp()
    );
  }

  /**
   * @notice allows bank operators to transfer margin from one account to another without logs
   * @dev settlement-only hot path helper to reduce data size overhead
   * @param _account address of account from which to take margin out
   * @param _destination address of destination where funds are to be deposited
   * @param _amount amount of margin to be transfered
   */
  function transferMarginToAccountSilent(
    address _account,
    address _destination,
    uint128 _amount
  ) external override nonReentrant onlyBankOPerators {
    Require.that(
      bankBalances[_account] >= _amount,
      'Insufficient account funds',
      _account
    );

    bankBalances[_account] -= _amount;
    bankBalances[_destination] += _amount;
  }

  function _requestWithdrawFromBank(
    address _owner,
    address _destination,
    uint128 _amount
  ) internal returns (uint128 requestId) {
    require(
      isWithdrawalAllowed(),
      'MarginBank: Withdrawals not allowed at the moment'
    );
    // Checked right after the Guardian withdrawal gate (and, in
    // requestWithdrawFromBank, the caller's system-account check), before the
    // destination, amount, pending-request and balance checks, so a bank whose
    // expiry migration has not run reports that plainly rather than masking it
    // behind one of those rejections.
    uint64 windowSeconds = _requireDirectWithdrawalExpiryInitialized();
    require(_destination != address(0), 'MarginBank: invalid destination');
    require(!systemAccounts[_owner], 'MarginBank: system account withdrawal');
    require(_amount > 0, 'MarginBank: invalid amount');
    _supersedeExpiredDirectWithdrawalRequest(_owner);
    require(
      activeDirectWithdrawalRequestByOwner[_owner] == 0,
      'MarginBank: pending withdrawal exists'
    );

    require(
      bankBalances[_owner] >= _amount,
      'MarginBank: insufficient balance'
    );

    if (nextDirectWithdrawalRequestId == 0) {
      nextDirectWithdrawalRequestId = 1;
    }
    requestId = nextDirectWithdrawalRequestId;
    nextDirectWithdrawalRequestId = requestId + 1;
    uint64 delaySeconds = directWithdrawalDelaySeconds;
    if (delaySeconds < MIN_DIRECT_WITHDRAWAL_DELAY_SECONDS) {
      delaySeconds = MIN_DIRECT_WITHDRAWAL_DELAY_SECONDS;
    }
    // Routed through the checked helper so the uint64 narrowing is bounds-tested
    // here too, rather than relying on a bare cast.
    uint64 requestedAt = _addSecondsToTimestamp(block.timestamp, 0);
    uint64 executableAt = _addSecondsToTimestamp(requestedAt, delaySeconds);
    uint64 expiresAt = _addSecondsToTimestamp(executableAt, windowSeconds);

    directWithdrawalRequests[requestId] = DirectWithdrawalRequest({
      owner: _owner,
      destination: _destination,
      amount: _amount,
      executableAt: executableAt,
      executed: false,
      cancelled: false,
      expiresAt: expiresAt
    });
    activeDirectWithdrawalRequestByOwner[_owner] = requestId;

    emit DirectWithdrawalRequested(
      _owner,
      _destination,
      _amount,
      requestId,
      requestedAt,
      executableAt,
      expiresAt
    );
  }

  /// @dev The owner's active request, or zero when it can no longer execute.
  /// Expiry is a deadline check rather than a state change, so an expired
  /// request lingers in storage with the owner's active slot still pointing at
  /// it. It must not go on blocking withdrawals it can never compete with. A
  /// request whose deadline is unknown (zero, i.e. a pre-upgrade entry on a bank
  /// whose migration has not run) keeps blocking — the conservative direction.
  function _blockingDirectWithdrawalRequestId(
    address _owner
  ) internal view returns (uint128) {
    uint128 requestId = activeDirectWithdrawalRequestByOwner[_owner];
    if (requestId == 0) {
      return 0;
    }
    uint64 expiresAt = directWithdrawalRequests[requestId].expiresAt;
    if (expiresAt != 0 && block.timestamp > expiresAt) {
      return 0;
    }
    return requestId;
  }

  /// @dev Retires an expired request so the owner can immediately create a new
  /// one. Without this the owner would have to send a separate cancellation
  /// first, for a request that already died on a timer, before the direct path
  /// accepted a new request; the relayed path already ignores an expired request
  /// (see `_blockingDirectWithdrawalRequestId`). Emits the ordinary cancellation
  /// event so off-chain consumers release whatever they hold against it through
  /// the path they already handle.
  function _supersedeExpiredDirectWithdrawalRequest(address _owner) internal {
    uint128 requestId = activeDirectWithdrawalRequestByOwner[_owner];
    if (requestId == 0 || _blockingDirectWithdrawalRequestId(_owner) != 0) {
      return;
    }
    directWithdrawalRequests[requestId].cancelled = true;
    activeDirectWithdrawalRequestByOwner[_owner] = 0;
    emit DirectWithdrawalCancelled(_owner, requestId);
  }

  /// @dev Reverts unless the expiry migration has run. Both the money paths that
  /// create and execute direct withdrawals call this, so an implementation
  /// upgrade that skips `initializeDirectWithdrawalExpiry` fails closed instead
  /// of minting requests that would never expire. Cancellation is deliberately
  /// left ungated so users can always retire a request.
  function _requireDirectWithdrawalExpiryInitialized()
    internal
    view
    returns (uint64 windowSeconds)
  {
    windowSeconds = directWithdrawalExecutionWindowSeconds;
    require(
      windowSeconds >= MIN_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS &&
        windowSeconds <= MAX_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS,
      'MarginBank: expiry not initialized'
    );
  }

  function _requireDirectWithdrawalExecutionWindowInRange(
    uint64 _windowSeconds
  ) internal pure {
    require(
      _windowSeconds >= MIN_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS &&
        _windowSeconds <= MAX_DIRECT_WITHDRAWAL_EXECUTION_WINDOW_SECONDS,
      'MarginBank: window out of range'
    );
  }

  function _requireSystemAccountBindingsMigrated() internal view {
    require(
      systemAccountBindingsMigrated,
      'MarginBank: system account bindings not migrated'
    );
  }

  function _requireAccountController(address _systemAccount) internal view {
    require(
      systemAccounts[_systemAccount],
      'MarginBank: unknown system account'
    );
    require(
      controllerOf[_systemAccount] == msg.sender,
      'MarginBank: caller does not control this system account'
    );
    require(
      isApprovedController[msg.sender],
      'MarginBank: caller is not an approved controller'
    );
  }

  /**
   * @dev Requires `_account` to have deployed code and to answer `controller()`
   * with `_controller`.
   *
   * Deliberately NOT a proof of canonical `SystemAccountHolder` bytecode: any
   * contract returning the expected address passes, and a contrived one could
   * return something different on a later call. That is acceptable because at
   * registration the caller is an owner-approved controller that can only name
   * itself, so it gains nothing it could not get by deploying a genuine holder —
   * the same authority over the same accounts. In the one-time migration the
   * caller is the owner or proxy admin, and every entry must already be a
   * system account. Nothing re-reads `controller()` after
   * the binding is written, so a shape-shifting answer buys nothing either.
   *
   * The stronger checks live where they can be maintained: off-chain tooling
   * corroborates every migrated account against the transaction that registered
   * it and against its controller's own enumeration. Pinning bytecode on-chain
   * was considered and rejected — the live fleets already run several holder
   * vintages (three distinct code hashes on testnet, two on mainnet), so a
   * codehash allowlist would be a list the owner must keep correct forever, and
   * a stale entry would block registration outright.
   */
  function _requireHolderControlledBy(
    address _account,
    address _controller
  ) internal view {
    require(
      _account.code.length > 0,
      'MarginBank: system account not contract'
    );
    try ISystemAccountHolder(_account).controller() returns (
      address holderController
    ) {
      require(
        holderController == _controller,
        'MarginBank: holder controller mismatch'
      );
    } catch {
      revert('MarginBank: account is not a system account holder');
    }
  }

  function _initializeDirectWithdrawalExpiry(uint64 _windowSeconds) internal {
    _requireDirectWithdrawalExecutionWindowInRange(_windowSeconds);
    directWithdrawalExecutionWindowSeconds = _windowSeconds;
    emit DirectWithdrawalExecutionWindowUpdate(_windowSeconds);
    emit DirectWithdrawalExpiryInitialized(_windowSeconds);
  }

  function _requireNoOutstandingDirectWithdrawalRequests() internal view {
    uint128 nextRequestId = nextDirectWithdrawalRequestId;
    require(nextRequestId != 0, 'MarginBank: invalid withdrawal counter');
    for (uint128 requestId = 1; requestId < nextRequestId; requestId++) {
      DirectWithdrawalRequest storage request = directWithdrawalRequests[
        requestId
      ];
      require(
        request.executed || request.cancelled,
        'MarginBank: outstanding direct withdrawal'
      );
    }
  }

  /// @dev Adds two second-denominated values in uint256 and rejects anything a
  /// uint64 timestamp field cannot hold, so neither the addition nor the cast
  /// can silently wrap. Taking the base as uint256 also covers a `block.timestamp`
  /// that would not itself fit in uint64.
  function _addSecondsToTimestamp(
    uint256 _timestamp,
    uint64 _secondsToAdd
  ) internal pure returns (uint64) {
    uint256 sum = _timestamp + uint256(_secondsToAdd);
    require(sum <= type(uint64).max, 'MarginBank: timestamp overflow');
    return uint64(sum);
  }

  function _executeWithdrawal(
    address _owner,
    address _destination,
    uint128 _amount,
    uint128 _feeAmount
  ) internal returns (uint128 ownerBalance) {
    require(
      isWithdrawalAllowed(),
      'MarginBank: Withdrawals not allowed at the moment'
    );
    require(_owner != address(0), 'MarginBank: invalid owner');
    require(_destination != address(0), 'MarginBank: invalid destination');
    require(!systemAccounts[_owner], 'MarginBank: system account withdrawal');
    require(_amount > 0, 'MarginBank: invalid amount');
    require(_feeAmount < _amount, 'MarginBank: invalid withdrawal fee');
    require(
      bankBalances[_owner] >= _amount,
      'MarginBank: insufficient balance'
    );

    uint128 amountOut = _amount - _feeAmount;
    bankBalances[_owner] -= _amount;
    _decreaseBankLiabilities(_amount);
    ownerBalance = bankBalances[_owner];
    SafeERC20.safeTransfer(IERC20(token), _destination, amountOut);
    if (_feeAmount > 0) {
      address feeRecipient = withdrawalFeeRecipient;
      require(feeRecipient != address(0), 'MarginBank: fee not configured');
      SafeERC20.safeTransfer(IERC20(token), feeRecipient, _feeAmount);
      emit WithdrawalFeeCharged(
        _owner,
        _destination,
        feeRecipient,
        _amount,
        _feeAmount,
        amountOut
      );
    }

    emit BankBalanceUpdate(
      Action.WITHDRAW,
      _owner,
      _destination,
      _amount,
      ownerBalance,
      bankBalances[_destination],
      _blockTimestamp()
    );
    _recordExternalWithdrawal(_owner, _amount);
  }

  function _quoteRelayedWithdrawal(
    uint128 _amount
  ) internal view returns (uint128 feeAmount, uint128 amountOut) {
    feeAmount = withdrawalFeeAmount;
    if (_amount <= feeAmount) {
      return (feeAmount, 0);
    }
    amountOut = _amount - feeAmount;
  }

  function _validatedWithdrawalQuote(
    uint128 _amount,
    uint128 _minimumAmountOut
  ) internal view returns (uint128 feeAmount, uint128 amountOut) {
    (feeAmount, amountOut) = _quoteRelayedWithdrawal(_amount);
    require(amountOut > 0, 'MarginBank: withdrawal amount does not cover fee');
    require(_minimumAmountOut > 0, 'MarginBank: invalid minimum amount out');
    require(
      amountOut >= _minimumAmountOut,
      'MarginBank: minimum amount out not met'
    );
  }

  function _executeWithdrawalFromAccount(
    address _owner,
    address _destination,
    uint128 _amount
  ) internal returns (uint128 ownerBalance) {
    require(
      isWithdrawalAllowed(),
      'MarginBank: Withdrawals not allowed at the moment'
    );
    require(_owner != address(0), 'MarginBank: invalid owner');
    require(_destination != address(0), 'MarginBank: invalid destination');
    require(_amount > 0, 'MarginBank: invalid amount');
    require(
      bankBalances[_owner] >= _amount,
      'MarginBank: insufficient balance'
    );

    bankBalances[_owner] -= _amount;
    _decreaseBankLiabilities(_amount);
    ownerBalance = bankBalances[_owner];
    SafeERC20.safeTransfer(IERC20(token), _destination, _amount);

    emit BankBalanceUpdate(
      Action.WITHDRAW,
      _owner,
      _destination,
      _amount,
      ownerBalance,
      bankBalances[_destination],
      _blockTimestamp()
    );
  }

  function _depositFrom(
    address _caller,
    address _account,
    uint128 _amount
  ) internal {
    _recordExternalDeposit(_account, _amount);

    // transfer amount from caller to margin bank for provided account
    /// @dev will revert if caller does not have enough funds
    SafeERC20.safeTransferFrom(IERC20(token), _caller, address(this), _amount);

    bankBalances[_account] += _amount;
    _increaseBankLiabilities(_amount);
    _requireSufficientCollateral();

    emit BankBalanceUpdate(
      Action.DEPOSIT,
      _caller,
      _account,
      _amount,
      bankBalances[_caller],
      bankBalances[_account],
      _blockTimestamp()
    );
  }

  function _recordExternalDeposit(address _account, uint128 _amount) internal {
    require(_account != address(0), 'MarginBank: invalid account');
    require(!systemAccounts[_account], 'MarginBank: system account deposit');
    require(_amount > 0, 'MarginBank: invalid amount');

    if (externalDepositCapExemptAccounts[_account]) {
      return;
    }

    uint256 nextExternalDepositAmount = uint256(netExternalDeposits[_account]) +
      _amount;
    require(
      nextExternalDepositAmount <= externalDepositCap,
      'MarginBank: deposit cap exceeded'
    );
    netExternalDeposits[_account] = uint128(nextExternalDepositAmount);
  }

  function _recordExternalWithdrawal(
    address _account,
    uint128 _amount
  ) internal {
    uint128 currentExternalDeposits = netExternalDeposits[_account];
    if (_amount >= currentExternalDeposits) {
      netExternalDeposits[_account] = 0;
      return;
    }

    netExternalDeposits[_account] = currentExternalDeposits - _amount;
  }

  function _increaseBankLiabilities(uint256 _amount) internal {
    totalBankLiabilities += _amount;
  }

  function _decreaseBankLiabilities(uint256 _amount) internal {
    totalBankLiabilities -= _amount;
  }

  function _requireSufficientCollateral() internal view {
    require(
      IERC20(token).balanceOf(address(this)) >= totalBankLiabilities,
      'MarginBank: liabilities exceed collateral'
    );
  }

  //===========================================================//
  //                         GETTERS
  //===========================================================//

  /**
   * @notice Get the bank balance of an account.
   * @param _account The address of the account to query the balances of.
   */
  function getAccountBankBalance(
    address _account
  ) external view override returns (uint128) {
    return bankBalances[_account];
  }

  function isSystemAccount(
    address _account
  ) external view override returns (bool) {
    return systemAccounts[_account];
  }

  /**
   * Returns true if withdrawals from this MarginBank are allowed (bank-wide) else false
   */
  function isWithdrawalAllowed() public view override returns (bool) {
    return withdrawalStatus == Types.GuardianStatus.ALLOWED;
  }
}
