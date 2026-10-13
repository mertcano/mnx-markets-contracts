// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ImmutableBackendPriceOracle} from './ImmutableBackendPriceOracle.sol';

/**
 * @title ImmutableBinaryBackendPriceOracle
 * @notice Immutable backend oracle for a payout price in (0, 1e18]. Each
 * update is bounded by a complement-symmetric fraction of the side that loses
 * in that direction:
 *
 *   down <= price * riskFractionE18
 *   up   <= (1e18-price) * riskFractionE18
 *
 * The inherited `maxUpdateBps()` getter deliberately returns zero. Its unit is
 * percentage-of-price and cannot faithfully describe the upward binary bound;
 * consumers must read `riskFractionE18()` instead.
 */
contract ImmutableBinaryBackendPriceOracle is ImmutableBackendPriceOracle {
  uint256 private constant BASE = 1e18;

  uint128 public immutable riskFractionE18;

  event BinaryRiskFractionSet(uint128 riskFractionE18);

  constructor(
    address initialOwner,
    address initialUpdater,
    int256 initialAnswer,
    uint8 decimals_,
    string memory description_,
    uint128 _maxStalenessSeconds,
    uint128 _riskFractionE18,
    uint128 _minUpdateIntervalSeconds
  )
    ImmutableBackendPriceOracle(
      initialOwner,
      initialUpdater,
      initialAnswer,
      decimals_,
      description_,
      _maxStalenessSeconds,
      0,
      _minUpdateIntervalSeconds
    )
  {
    require(initialAnswer <= int256(BASE), 'IBBPO: price exceeds payout');
    require(
      _riskFractionE18 > 0 && _riskFractionE18 <= BASE,
      'IBBPO: risk fraction out of range'
    );
    require(_minUpdateIntervalSeconds > 0, 'IBBPO: interval is zero');
    riskFractionE18 = _riskFractionE18;
    emit BinaryRiskFractionSet(_riskFractionE18);
  }

  function setPrice(int256 newAnswer) external override {
    require(updaters[_msgSender()], 'IBPO: not updater');
    _validateAnswer(newAnswer);
    require(newAnswer <= int256(BASE), 'IBBPO: price exceeds payout');

    if (_latestRound > 0) {
      uint256 previous = uint256(_answers[_latestRound]);
      uint256 next = uint256(newAnswer);
      uint256 sideCapacity = next > previous ? BASE - previous : previous;
      uint256 allowedDelta = (sideCapacity * uint256(riskFractionE18)) / BASE;
      uint256 actualDelta = next > previous ? next - previous : previous - next;
      require(actualDelta <= allowedDelta, 'IBBPO: change too large');
    }

    _writeNewRound(newAnswer);
  }
}
