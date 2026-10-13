// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from '../libraries/Types.sol';

interface IBackstopVault {
  /**
   * @notice Authorizes a registered child to receive a distressed position.
   * @dev The calling Perpetual must first enforce its positive-equity backstop
   * trigger. The position and its remaining isolated margin transfer together;
   * the resulting positive residual equity is retained by the child as the
   * insurance fee for assuming the position's tail risk, not refunded.
   */
  function inheritPosition(
    address account,
    address market,
    Types.PositionBalance calldata position
  ) external returns (bytes32 inheritanceId, address inheritingChild);

  function isRegisteredChildVault(address account) external view returns (bool);

  function mainVaultAddress() external view returns (address);
}
