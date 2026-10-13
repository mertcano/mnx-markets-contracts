// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/**
 * @title ISystemAccountHolder
 * @notice The one thing a system account has to be able to answer: who controls it.
 * @dev `SystemAccountHolder.controller` is immutable, so MarginBank and
 * AccountManager can treat the answer as permanent when they bind an account to
 * a controller.
 */
interface ISystemAccountHolder {
  function controller() external view returns (address);
}
