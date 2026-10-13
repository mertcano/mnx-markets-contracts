// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IPerpetual} from './interfaces/IPerpetual.sol';

/**
 * @title GlobalIndexUpdater
 * @notice Refreshes the funding index for many markets in one transaction.
 * @dev Each market call is isolated so one stale or otherwise unhealthy market
 * does not prevent healthy markets from refreshing.
 */
contract GlobalIndexUpdater {
  uint256 public constant MARKET_CALL_GAS_LIMIT = 250_000;
  uint256 public constant MAX_RETURN_DATA_BYTES = 256;

  event GlobalIndexRefreshResult(
    address indexed market,
    bool success,
    bytes returnData
  );

  function updateGlobalIndexes(address[] calldata markets) external {
    for (uint256 i = 0; i < markets.length; ++i) {
      address market = markets[i];
      if (market.code.length == 0) {
        emit GlobalIndexRefreshResult(
          market,
          false,
          bytes('MARKET_NOT_CONTRACT')
        );
        continue;
      }

      (bool success, bytes memory returnData) = _updateMarket(market);
      emit GlobalIndexRefreshResult(market, success, returnData);
    }
  }

  function _updateMarket(
    address market
  ) private returns (bool success, bytes memory returnData) {
    bytes memory callData = abi.encodeCall(IPerpetual.updateGlobalIndex, ());
    uint256 marketCallGasLimit = MARKET_CALL_GAS_LIMIT;
    uint256 maxReturnDataBytes = MAX_RETURN_DATA_BYTES;
    assembly ('memory-safe') {
      success := call(
        marketCallGasLimit,
        market,
        0,
        add(callData, 0x20),
        mload(callData),
        0,
        0
      )

      let returnDataSize := returndatasize()
      if gt(returnDataSize, maxReturnDataBytes) {
        returnDataSize := maxReturnDataBytes
      }
      returnData := mload(0x40)
      mstore(returnData, returnDataSize)
      returndatacopy(add(returnData, 0x20), 0, returnDataSize)
      mstore(
        0x40,
        and(add(add(returnData, 0x20), add(returnDataSize, 0x1f)), not(0x1f))
      )
    }
  }
}
