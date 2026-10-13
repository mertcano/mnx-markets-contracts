// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/**
 * @title IOracleFactory
 * @notice The immutable-oracle provenance predicate consumed by Perpetual.
 */
interface IOracleFactory {
  /**
   * @notice Exact cadence required for binary oracle updates.
   */
  function BINARY_ORACLE_MIN_UPDATE_INTERVAL_SECONDS()
    external
    view
    returns (uint128);

  /**
   * @notice Returns true for an oracle minted by this factory generation or
   * one of its immutable predecessor generations.
   */
  function isFactoryOracle(address oracle) external view returns (bool);
}
