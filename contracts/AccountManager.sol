// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';
import {ERC1967Utils} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol';
import {BaseRelayRecipient} from './utils/BaseRelayRecipient.sol';
import {IAccountManager} from './interfaces/IAccountManager.sol';
import {ISystemAccountHolder} from './interfaces/ISystemAccountHolder.sol';
import {Types} from './libraries/Types.sol';

/**
 * @title AccountManager
 * @author MNX Markets <help@mnx.fi>
 * @notice Centralized management of sub-account relationships for all Perpetual contracts
 * @dev This contract allows users to authorize session keys once for all markets,
 *      eliminating the need to call setSubAccount on each individual Perpetual contract.
 *      Supports gasless transactions via EIP-2771 meta-transactions.
 *
 *      The contract is upgradeable behind a proxy; do not change the order of
 *      the state variables below.
 */
contract AccountManager is
  IAccountManager,
  Ownable2StepUpgradeable,
  BaseRelayRecipient
{
  //
  // STATE
  //

  /// @notice Mapping of user => operator => approved status
  /// @dev user is the main account, operator is the session key or sub-account
  mapping(address => mapping(address => bool)) internal subAccounts;

  /// @notice DEPRECATED (audit #70). Protocol-wide controller approvals.
  /// @dev No authorization path reads this mapping any more — authority comes
  /// from `controllerOf` plus `isApprovedController`. The slot is kept, and must
  /// never be reused, so the layout of every live proxy stays valid and so the
  /// migration campaign can prove the old approvals were revoked. There is no
  /// setter left; `initializeSystemAccountBindings` clears the entries the
  /// reviewed inventory found.
  mapping(address => bool) public systemSubAccountControllers;

  //◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤ add state variables below ◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤//

  /// @notice The single controller each system account is bound to (audit #70).
  /// @dev Append-only, and identical in meaning to MarginBank's binding of the
  /// same name: written once by the registration that checked the account is
  /// a contract whose `controller()` returns the registering caller, or by the
  /// one-time migration for accounts that predate it.
  mapping(address => address) public controllerOf;

  /// @notice Contracts the owner allows to register and control system accounts.
  /// @dev Checked together with `controllerOf`, never instead of it.
  mapping(address => bool) public isApprovedController;

  /// @notice Set by `initialize` on a fresh deployment and at the end of
  /// `initializeSystemAccountBindings` on an upgraded proxy.
  bool public systemAccountBindingsMigrated;

  /// @notice Per-market authority for system-account operators (audit #38).
  /// @dev account => operator => market => permission. Only consulted for system
  /// accounts, meaning those with a `controllerOf` binding; ordinary users keep
  /// the global `subAccounts` model untouched. An unwritten entry is `NONE`, so
  /// a market that nobody granted is closed.
  mapping(address => mapping(address => mapping(address => Types.MarketPermission)))
    internal systemMarketPermissions;

  /// @notice Set by `initialize` on a fresh deployment and at the end of
  /// `initializeMarketPermissions` on an upgraded proxy, which populates the
  /// pre-existing (account, operator, market) permissions from the reviewed
  /// inventory (audit #38).
  /// @dev Separate from `systemAccountBindingsMigrated`: #70 established WHO
  /// controls an account, this establishes WHERE its operators may act. Until it
  /// is set, `setSystemMarketPermission` refuses `ACTIVE`. `NONE` and
  /// `REDUCE_ONLY` are still accepted, so an operator can be raised from `NONE`
  /// to `REDUCE_ONLY` before the migration completes.
  bool public marketPermissionsMigrated;

  //◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣ add state variables above ◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣//

  /// @notice A system account was registered and permanently bound to a controller.
  event SystemAccountRegistered(
    address indexed account,
    address indexed controller
  );
  /// @notice The owner allowed or revoked a system-account controller.
  event ApprovedControllerUpdate(address indexed controller, bool approved);
  /// @notice Emitted once when the #70 binding migration runs on an upgraded proxy.
  /// @dev One count, not two: an approval is only ever created here by carrying
  ///      a revoked deprecated one forward, so an "approved controller count"
  ///      could never differ from the revoked count.
  event SystemAccountBindingsInitialized(
    uint256 accountCount,
    uint256 revokedDeprecatedControllerCount,
    bytes32 inventoryChecksum
  );
  /// @notice A deprecated protocol-wide controller approval was cleared.
  event DeprecatedSystemSubAccountControllerRevoked(address indexed controller);
  /// @notice A system account's operator permission changed for one market.
  event SystemMarketPermissionUpdate(
    address indexed account,
    address indexed operator,
    address indexed market,
    Types.MarketPermission permission
  );
  /// @notice Emitted once when the #38 market-permission migration runs.
  event MarketPermissionsInitialized(
    uint256 permissionCount,
    bytes32 inventoryChecksum
  );

  //
  // INITIALIZATION
  //

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Initializes the AccountManager contract
   * @param _trustedForwarder Address of the MinimalForwarder for gasless transactions
   */
  function initialize(address _trustedForwarder) external initializer {
    __Ownable_init(_msgSender());
    __Ownable2Step_init();
    // A fresh deployment has no system accounts, so there is nothing to migrate
    // and controller registration is open from the start. The same is true of
    // market permissions: with no pre-existing operators there is no picture to
    // populate first, so granting is open immediately (audit #38).
    systemAccountBindingsMigrated = true;
    marketPermissionsMigrated = true;
    _setTrustedForwarder(_trustedForwarder);
  }

  /**
   * @notice Binds every system account that predates per-controller isolation
   *         to the controller that owns it (audit issue #70).
   * @dev Runs exactly once, as reinitializer version 2 — the next unused version
   *      on the live proxies, which read `_initialized == 1` before this upgrade.
   *      It must run in the
   *      same transaction as the upgrade (`ProxyAdmin.upgradeAndCall`), which is
   *      why the ERC-1967 proxy admin is accepted alongside the owner: during
   *      `upgradeAndCall` the delegatecall into this implementation sees the
   *      ProxyAdmin as `msg.sender`.
   *
   *      Mirrors MarginBank's migration deliberately, down to the argument
   *      shape, so one reviewed inventory drives both and an operator never has
   *      to work out which subset of accounts belongs to which contract.
   *      Existing `subAccounts` grants are untouched; only the authority to
   *      change them is being narrowed.
   * @param _accounts Every existing system account, from the reviewed inventory.
   * @param _controllers The controller of each account, positionally paired.
   * @param _deprecatedControllersToRevoke Addresses still holding a deprecated
   *        protocol-wide approval.
   * @param _inventoryChecksum Digest of the reviewed inventory artifact.
   */
  function initializeSystemAccountBindings(
    address[] calldata _accounts,
    address[] calldata _controllers,
    address[] calldata _deprecatedControllersToRevoke,
    bytes32 _inventoryChecksum
  ) external reinitializer(2) {
    require(
      msg.sender == owner() || msg.sender == ERC1967Utils.getAdmin(),
      'AccountManager: caller cannot initialize bindings'
    );
    require(
      _accounts.length == _controllers.length,
      'AccountManager: binding length mismatch'
    );
    // Empty is allowed for the same reason as MarginBank: an unbootstrapped
    // environment must still be able to migrate, and its controller still
    // carries its approval forward below. See that contract's note.
    require(
      _inventoryChecksum != bytes32(0),
      'AccountManager: invalid inventory checksum'
    );

    // Binding and approval are separate decisions; see MarginBank's note. The
    // binding is a fact about the holder and is always written, so no account is
    // stranded. The approval is the owner's current intent and is carried
    // forward only from what they approve right now.
    for (uint256 i = 0; i < _accounts.length; i++) {
      address account = _accounts[i];
      address controller = _controllers[i];
      require(
        controllerOf[account] == address(0),
        'AccountManager: duplicate inventory account'
      );
      _requireHolderControlledBy(account, controller);

      controllerOf[account] = controller;
      emit SystemAccountRegistered(account, controller);
    }

    uint256 revokedControllerCount = 0;
    for (uint256 i = 0; i < _deprecatedControllersToRevoke.length; i++) {
      address deprecatedController = _deprecatedControllersToRevoke[i];
      if (!systemSubAccountControllers[deprecatedController]) continue;

      require(
        deprecatedController.code.length > 0,
        'AccountManager: controller not contract'
      );
      systemSubAccountControllers[deprecatedController] = false;
      isApprovedController[deprecatedController] = true;
      revokedControllerCount += 1;
      emit DeprecatedSystemSubAccountControllerRevoked(deprecatedController);
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

  //
  // PUBLIC FUNCTIONS
  //

  /**
   * @notice Grants or revokes permission for another account to perform actions on behalf of the sender
   * @dev Uses _msgSender() to support EIP-2771 meta-transactions
   * @param  operator  The account that is approved or disapproved
   * @param  approved  True for approval, false for disapproval
   */
  function setSubAccount(address operator, bool approved) external override {
    require(operator != address(0), 'AccountManager: invalid operator');
    subAccounts[_msgSender()][operator] = approved;
    emit SubAccountUpdate(_msgSender(), operator, approved);
  }

  /// @notice An operator gives up its own grant on `user`. Restrict-only and
  /// idempotent; emits the same event the grant path emits so off-chain
  /// indexers need no new case.
  function renounceSubAccount(address user) external {
    _requireSystemAccountBindingsMigrated();
    require(controllerOf[user] == address(0), 'AccountManager: system account');
    subAccounts[user][_msgSender()] = false;
    emit SubAccountUpdate(user, _msgSender(), false);
  }

  /**
   * @notice Registers a system account and binds it to the calling controller.
   * @dev Same check MarginBank requires: an approved controller registering a
   * contract whose `controller()` returns that caller. Without it a controller
   * could register an ordinary user here and
   * hand itself — or an attacker — trading permission over that user's account.
   */
  function registerSystemAccount(address account) external override {
    _requireSystemAccountBindingsMigrated();
    require(
      isApprovedController[msg.sender],
      'AccountManager: caller is not an approved controller'
    );
    require(account != address(0), 'AccountManager: invalid system account');
    require(
      controllerOf[account] == address(0),
      'AccountManager: system account already bound'
    );
    _requireHolderControlledBy(account, msg.sender);

    controllerOf[account] = msg.sender;
    emit SystemAccountRegistered(account, msg.sender);
  }

  /**
   * @notice Sets or clears the global `subAccounts` flag for a system account's
   * operator. The flag carries no authority: `accountMarketPermission` never
   * reads it for a system account, so it only changes what `isSubAccount`
   * reports. Market authority is set with `setSystemMarketPermission`.
   * @dev Only the controller the account is bound to may call this. The owner
   * has no bypass: nothing in production needs one, and the owner branch this
   * replaces was reachable through the trusted forwarder, so removing it also
   * removes a forged-sender route into other users' permissions.
   *
   * Reads `msg.sender` rather than the forwarder-aware `_msgSender()` for the
   * same reason — controllers are contracts that call this directly, and no
   * controller path is ever relayed.
   */
  function setSystemSubAccount(
    address user,
    address operator,
    bool approved
  ) external override {
    _requireSystemAccountBindingsMigrated();
    require(
      controllerOf[user] == msg.sender,
      'AccountManager: caller does not control this system account'
    );
    require(
      isApprovedController[msg.sender],
      'AccountManager: caller is not an approved controller'
    );
    require(operator != address(0), 'AccountManager: invalid operator');
    subAccounts[user][operator] = approved;
    emit SubAccountUpdate(user, operator, approved);
  }

  /**
   * @notice Allows or revokes a contract's ability to control system accounts.
   * @dev Approval alone grants authority over nothing: `setSystemSubAccount`
   * also requires the account to be bound to the caller. Revoking is the only
   * way to stop a compromised controller, because bindings are append-only.
   */
  function setApprovedController(
    address controller,
    bool approved
  ) external override onlyOwner {
    require(controller != address(0), 'AccountManager: invalid controller');
    if (approved) {
      require(
        controller.code.length > 0,
        'AccountManager: controller not contract'
      );
    }
    isApprovedController[controller] = approved;
    emit ApprovedControllerUpdate(controller, approved);
  }

  /**
   * @notice Sets what an operator may do for a system account in one market.
   * @dev Same authority as `setSystemSubAccount`: the controller the account is
   * bound to, which must itself still be approved. Reads `msg.sender` rather
   * than `_msgSender()` for the same reason — controllers are contracts calling
   * directly, and no controller path is ever relayed.
   *
   * Granting `ACTIVE` requires the migration to have completed, so full trading
   * authority is never handed out against a half-populated picture. `NONE` and
   * `REDUCE_ONLY` are accepted regardless of migration state so a wind-down is
   * never blocked by it. `REDUCE_ONLY` written over `NONE` is still a grant: the
   * operator may then sign reduce-only orders, add margin, lower leverage, and
   * close after a delisting for this account in this market.
   */
  function setSystemMarketPermission(
    address account,
    address operator,
    address market,
    Types.MarketPermission permission
  ) external override {
    require(
      controllerOf[account] == msg.sender,
      'AccountManager: caller does not control this system account'
    );
    require(
      isApprovedController[msg.sender],
      'AccountManager: caller is not an approved controller'
    );
    require(operator != address(0), 'AccountManager: invalid operator');
    require(market != address(0), 'AccountManager: invalid market');
    if (permission == Types.MarketPermission.ACTIVE) {
      require(
        marketPermissionsMigrated,
        'AccountManager: market permissions not migrated'
      );
    }

    systemMarketPermissions[account][operator][market] = permission;
    emit SystemMarketPermissionUpdate(account, operator, market, permission);
  }

  /**
   * @notice Populates every market permission that predates issue #38.
   * @dev Reinitializer version 3: version 1 was `initialize`, version 2 was
   *      #70's `initializeSystemAccountBindings`. Runs in the same transaction
   *      as the upgrade, which is why the ERC-1967 proxy admin is accepted
   *      alongside the owner.
   *
   *      Requires #70's bindings to already exist. Without them there is no way
   *      to tell a system account from an ordinary user, so a permission written
   *      here could not be authorized against anything.
   *
   *      The migration only WRITES permissions. Revoking the global approvals
   *      these replace is a separate, later step in the campaign, after the
   *      entries have been read back and verified — never revoke first and
   *      strand a live position with no way to close it.
   */
  function initializeMarketPermissions(
    address[] calldata _accounts,
    address[] calldata _operators,
    address[] calldata _markets,
    Types.MarketPermission[] calldata _permissions,
    bytes32 _inventoryChecksum
  ) external reinitializer(3) {
    require(
      msg.sender == owner() || msg.sender == ERC1967Utils.getAdmin(),
      'AccountManager: caller cannot initialize permissions'
    );
    require(
      systemAccountBindingsMigrated,
      'AccountManager: system account bindings not migrated'
    );
    require(
      _accounts.length == _operators.length &&
        _accounts.length == _markets.length &&
        _accounts.length == _permissions.length,
      'AccountManager: permission length mismatch'
    );
    require(
      _inventoryChecksum != bytes32(0),
      'AccountManager: invalid inventory checksum'
    );

    for (uint256 i = 0; i < _accounts.length; i++) {
      address account = _accounts[i];
      address operator = _operators[i];
      address market = _markets[i];
      // Every entry must name a real system account. An ordinary user has no
      // binding, and writing a market permission for one would create a second,
      // parallel authority model over an account whose owner never asked for it.
      require(
        controllerOf[account] != address(0),
        'AccountManager: inventory account is not a system account'
      );
      require(operator != address(0), 'AccountManager: invalid operator');
      require(market != address(0), 'AccountManager: invalid market');
      require(
        _permissions[i] != Types.MarketPermission.NONE,
        'AccountManager: inventory permission is NONE'
      );
      require(
        systemMarketPermissions[account][operator][market] ==
          Types.MarketPermission.NONE,
        'AccountManager: duplicate inventory permission'
      );

      systemMarketPermissions[account][operator][market] = _permissions[i];
      emit SystemMarketPermissionUpdate(
        account,
        operator,
        market,
        _permissions[i]
      );
    }

    marketPermissionsMigrated = true;
    emit MarketPermissionsInitialized(_accounts.length, _inventoryChecksum);
  }

  /**
   * @notice What `operator` may do for `account` in `market`.
   * @dev The single authorization entry point for markets. A system account is
   * market-scoped and NEVER falls back to the global `subAccounts` mapping —
   * that fallback is exactly the finding. An ordinary user is unchanged: global
   * approval, valid in every market.
   *
   * A revoked controller's grants evaluate to NONE while the revocation lasts.
   * Revocation is the only way to stop a compromised controller, and after it
   * neither the controller (no longer approved) nor the owner (controls no
   * accounts) can clear the stored grants — so an evaluated grant that survived
   * revocation would be live authority nobody can remove. The records stay
   * written, so re-approval restores them without re-granting.
   */
  function accountMarketPermission(
    address account,
    address operator,
    address market
  ) external view override returns (Types.MarketPermission) {
    if (account == address(0) || operator == address(0)) {
      return Types.MarketPermission.NONE;
    }
    address controller = controllerOf[account];
    if (controller != address(0)) {
      if (!isApprovedController[controller]) {
        return Types.MarketPermission.NONE;
      }
      return systemMarketPermissions[account][operator][market];
    }
    // Ordinary user. Acting for yourself, or through a global subaccount grant.
    if (account == operator || subAccounts[account][operator]) {
      return Types.MarketPermission.ACTIVE;
    }
    return Types.MarketPermission.NONE;
  }

  /**
   * @notice The stored market permission, without the ordinary-user fallback.
   * @dev For operators and migration verification. Returns `NONE` for an
   * ordinary user regardless of their global approval, so a reader can tell the
   * two models apart.
   */
  function systemMarketPermission(
    address account,
    address operator,
    address market
  ) external view override returns (Types.MarketPermission) {
    return systemMarketPermissions[account][operator][market];
  }

  /**
   * @notice Whether an account is a system account, i.e. has a #70 binding.
   */
  function isSystemAccount(
    address account
  ) external view override returns (bool) {
    return controllerOf[account] != address(0);
  }

  /**
   * @notice Returns the global `subAccounts` approval of `operator` for `user`
   * @dev Not the market authorization check: markets call
   * `accountMarketPermission`, which never reads this flag for a system account
   * and authorizes an ordinary user to act for itself.
   * @param  user      The main account
   * @param  operator  The operator to check
   * @return           True if both addresses are nonzero and the global approval is set
   */
  function isSubAccount(
    address user,
    address operator
  ) external view override returns (bool) {
    // A failed signature recovery can yield address(0), so legacy zero-address
    // approvals must never authorize either side of this relationship.
    return
      user != address(0) &&
      operator != address(0) &&
      subAccounts[user][operator];
  }

  //
  // INTERNAL FUNCTIONS
  //

  function _requireSystemAccountBindingsMigrated() internal view {
    require(
      systemAccountBindingsMigrated,
      'AccountManager: system account bindings not migrated'
    );
  }

  /**
   * @dev Requires `account` to have deployed code and to answer `controller()`
   * with `controller`. Not a proof of canonical `SystemAccountHolder` bytecode —
   * see MarginBank's matching note for why that is acceptable and why pinning
   * bytecode on-chain was rejected.
   */
  function _requireHolderControlledBy(
    address account,
    address controller
  ) internal view {
    require(
      account.code.length > 0,
      'AccountManager: system account not contract'
    );
    try ISystemAccountHolder(account).controller() returns (
      address holderController
    ) {
      require(
        holderController == controller,
        'AccountManager: holder controller mismatch'
      );
    } catch {
      revert('AccountManager: account is not a system account holder');
    }
  }

  /**
   * @notice Returns the message sender (supports EIP-2771 meta-transactions)
   * @dev Uses msgSender from BaseRelayRecipient to enable gasless transactions
   */
  function _msgSender() internal view override returns (address) {
    return msgSender();
  }

  /**
   * @notice Returns the fixed recipient version string '1'
   * @dev Informational only, kept from the OpenGSN recipient interface. Nothing
   * in this repository reads it: MNXMinimalForwarder never calls it, and
   * AccountManager has no EIP-712 domain of its own.
   */
  function versionRecipient() external pure returns (string memory) {
    return '1';
  }
}
