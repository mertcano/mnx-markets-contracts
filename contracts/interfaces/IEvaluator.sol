// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from '../libraries/Types.sol';

interface IEvaluator {
  /**
   * @dev verifies that an executed fill quantity sits on the tradable
   * quantity grid: at or above `minQty` and aligned to `stepSize`. This is a
   * per-fill check and deliberately applies neither order-type maximum; the
   * maximums bound a signed order's own total quantity, which is what
   * `verifySignedOrderQuantityCap` checks.
   * @param _fillQuantity the executed quantity of a single fill
   * @param _account address blamed in the revert reason
   */
  function verifyFillQuantityGrid(
    uint128 _fillQuantity,
    address _account
  ) external view;

  /**
   * @dev verifies a signed order's own total quantity against the maximum
   * for its order type: `maxQtyMarket` for market orders and `maxQtyLimit`
   * for limit orders. Callers classify the order before any execution price
   * is substituted into a zero-price market order.
   * @param _orderQuantity the total quantity the order was signed for
   * @param _isMarketOrder true when the signed order carried a zero price
   * @param _account address blamed in the revert reason
   */
  function verifySignedOrderQuantityCap(
    uint128 _orderQuantity,
    bool _isMarketOrder,
    address _account
  ) external view;

  /**
   * @dev verifies if the trade price conforms to price checks
   * @param _price the price of trade
   */
  function verifyPriceChecks(uint128 _price, address _maker) external view;

  /**
   * @dev verifies if the trade price conforms to min max price checks
   * @param _price the price of trade
   */
  function verifyMinMaxPriceChecks(
    uint128 _price,
    address _maker
  ) external view;

  /**
   * @dev verifies that the trade price is within the market take bound on the
   * one side `_isBuy` selects: at most oracle + bound for a buy, at least
   * oracle - bound for a sell
   * @param _tradePrice the price of trade
   * @param _oraclePrice the price of oracle
   * @param _isBuy buy flag of the order being checked. IsolatedTrader checks
   * the taker's order, and the maker's too when it is a zero-price market order
   * @param _taker account that placed the order being checked; blamed in the
   * revert reason
   */
  function verifyMarketTakeBoundChecks(
    uint128 _tradePrice,
    uint128 _oraclePrice,
    bool _isBuy,
    address _taker
  ) external view;

  /**
   * @dev Legacy raw trigger-band view. For a binary market's zero sentinel,
   * this cannot express the price-dependent directional amount; enforcement
   * callers must use `triggerBandAmountFor`.
   * @param _isBuy the buy flag of the order being checked, maker or taker alike
   */
  function triggerBandFor(bool _isBuy) external view returns (uint128);

  /**
   * @dev Returns an absolute price amount. A positive explicit binary band is
   * already an absolute payout-price delta; a binary zero sentinel derives the
   * price-dependent directional take amount from remaining side capacity.
   */
  function triggerBandAmountFor(
    bool _isBuy,
    uint128 _oraclePrice
  ) external view returns (uint128);

  function binaryTakeRiskFraction() external view returns (uint128);

  function binaryTakeBoundAmountFor(
    bool _isBuy,
    uint128 _oraclePrice
  ) external view returns (uint128);

  /**
   * @dev verifies if the provided account has open notional <= maximum
   * allowed open notional for current leverage. A leverage tier outside the
   * configured range, or configured with a zero cap, is disabled and fails
   * this check for any position with nonzero open notional.
   * @param _account address of account
   * @param _balance Position balance of the account
   * @param _oraclePrice Current oracle price used to compute open notional
   */
  function verifyOpenNotionalForAccount(
    address _account,
    Types.PositionBalance memory _balance,
    uint128 _oraclePrice
  ) external view;

  /**
   * @dev verifies an account update against the open-notional cap of its
   * selected leverage tier. The before balance uses the old leverage tier and
   * the after balance uses the new leverage tier. Risk-increasing updates
   * (quantity growth, flips, higher selected leverage) must end with zero cap
   * excess; everything else only has to not increase the excess, so positions
   * in a tightened or disabled tier stay reducible and closable.
   * @param _account address of account
   * @param _beforeBalance Position balance before the update
   * @param _afterBalance Position balance after the update
   * @param _oraclePrice Current oracle price used to compute open notional
   */
  function verifyOpenNotionalTransitionForAccount(
    address _account,
    Types.PositionBalance memory _beforeBalance,
    Types.PositionBalance memory _afterBalance,
    uint128 _oraclePrice
  ) external view;

  /**
   * @notice returns the minimum allowed price for trade
   */
  function minPrice() external view returns (uint128);

  /**
   * @notice returns the maximum allowed price for trade
   */
  function maxPrice() external view returns (uint128);

  /**
   * @notice returns the tick size for price
   */
  function tickSize() external view returns (uint128);

  /**
   * @notice returns the minimum allowed quantity for order
   */
  function minQty() external view returns (uint128);

  /**
   * @notice returns the max allowed quantity for limit order
   */
  function maxQtyLimit() external view returns (uint128);

  /**
   * @notice returns the max allowed quantity for market order
   */
  function maxQtyMarket() external view returns (uint128);

  /**
   * @notice returns the quantity step size
   */
  function stepSize() external view returns (uint128);

  /**
   * @notice Returns the buy-side take-bound fraction that non-binary markets
   * enforce. Binary enforcement uses `binaryTakeBoundAmountFor` instead.
   */
  function mtbLong() external view returns (uint128);

  /**
   * @notice Returns the sell-side take-bound fraction that non-binary markets
   * enforce. Binary enforcement uses `binaryTakeBoundAmountFor` instead.
   */
  function mtbShort() external view returns (uint128);

  /**
   * @notice returns the stored open-notional cap for the provided leverage
   * @dev Raw storage. A cap is enforced only for tiers 1x through
   * `maxOpenNotionalTierCount`, and a zero cap disables its tier; a tier above
   * that count is disabled whatever this returns. Only stored for 1,2,3...N
   * leverage, not for 1.2 or other floating values
   * @param _leverage value of leverage in 1e18 format
   */
  function maxAllowedOpenNotional(
    uint128 _leverage
  ) external view returns (uint128);

  /**
   * @notice Returns true once binary-market price bounds are locked.
   */
  function binaryMarketPriceBoundsLocked() external view returns (bool);
}
