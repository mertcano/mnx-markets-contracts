// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/**
 * @title SystemAccountHolder
 * @notice Deterministic address holder used for vault-owned MarginBank accounts.
 * @dev The holder intentionally exposes no fund movement methods. LiquidityVault
 * controls MarginBank system-account primitives directly.
 */
contract SystemAccountHolder {
  address public immutable controller;

  constructor(address _controller) {
    require(_controller != address(0), 'SystemAccountHolder: controller zero');
    controller = _controller;
  }
}
