// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// utils
import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {BlockContext} from './utils/BlockContext.sol';

// interfaces
import {IPerpetual} from './interfaces/IPerpetual.sol';
import {ITrader} from './interfaces/ITrader.sol';
import {IEvaluator} from './interfaces/IEvaluator.sol';

// maths
import {BaseMath} from './maths/BaseMath.sol';
import {PositionBalanceMath} from './maths/PositionBalanceMath.sol';

// libraries
import {Types} from './libraries/Types.sol';
import {Require} from './libraries/Require.sol';

/**
 * @title Isolated Auto Deleveraging
 * @author MNX Markets <help@mnx.fi>
 * @notice Used to perform on-chain deleveraging of accounts.
 * The trade method on the contract is only invokable by the perpetual contract.
 * A whitelisted settlement operator must invoke trade on the perpetual with this
 * contract as the trader to deleverage accounts.
 * @dev The contract is made upgradable using openzeppelin upgrades-pluging, don't change
 * the order of variables. Read more: https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies
 */
contract IsolatedADL is
  ITrader,
  Ownable2StepUpgradeable,
  ReentrancyGuard,
  BlockContext
{
  using BaseMath for uint128;
  using BaseMath for int256;
  using PositionBalanceMath for Types.PositionBalance;

  //
  // STRUCTS
  //

  /// @dev Trade data expected by trade method of this contract
  struct TradeData {
    uint128 quantity;
    bool isBuy; // from taker's perspective
    bool allOrNothing; // if true, will revert if maker's position is less than the amount
  }

  /// @dev response returned by _applyIM method
  struct IMResponse {
    Types.PositionBalance updatedBalance;
    int256 fundsFlow;
    int256 pnl;
  }

  //**********************************************************//
  //    The below state variables can not change the order    //
  //**********************************************************//

  /// @dev Trader flag 3 (Perpetual's ADL_TRADER_FLAG) for this contract
  bytes32 public constant TRADER_ID = bytes32(uint256(3));

  /// @notice address of the perpetual contract
  address public perpetual;

  /// @dev Deprecated storage retained only to preserve the proxy layout.
  /// This contract has never used a margin bank directly. Do not reuse this
  /// slot or expose it as an authoritative dependency.
  address private marginBank;

  /// @notice address of the evaluator contract
  address public evaluator;

  uint256[50] private __gap;

  //**********************************************************//
  //    The above state variables can not change the order    //
  //**********************************************************//

  //◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤ add state variables below ◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤//

  //◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣ add state variables above ◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣//

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice initializes the contract
   * @dev makes the caller of initialize the owner; this contract has no cancellation operator
   * @param _perpetual address of perpetual contract
   * @param _evelautor address of evaluator contract
   */
  function initialize(
    address _perpetual,
    address _evelautor
  ) public initializer {
    perpetual = _perpetual;
    evaluator = _evelautor;

    __Ownable_init(_msgSender());
    __Ownable2Step_init();
  }

  /**
   * @notice Deleveraging trade, run when a whitelisted settlement operator calls
   * Perpetual.trade with this contract, for a maker whose margin ratio at the
   * oracle price is at or below zero. Both positions are reduced by
   * min(quantity, maker.qPos, taker.qPos).
   * @param  maker   bankrupt account
   * @param  taker   opposite-side account with a positive margin ratio at the
   * oracle price and non-negative equity at the bankruptcy price
   * @param  price   Current oracle price of asset
   * @param  data    Deleveraging trade data struct (of type TradeData)
   * @return         TradeResult indicating the result of Deleveraging
   */
  function trade(
    address maker,
    address taker,
    uint128 price,
    bytes calldata data,
    uint128 /* tradeTimestamp */
  ) external override nonReentrant returns (Types.TradeResult memory) {
    require(
      _msgSender() == perpetual,
      'IsolatedADL: Msg sender must be Perpetual'
    );

    TradeData memory tradeData = abi.decode(data, (TradeData));

    Types.PositionBalance memory makerBalance = IPerpetual(perpetual)
      .getAccountBalance(maker);

    Types.PositionBalance memory takerBalance = IPerpetual(perpetual)
      .getAccountBalance(taker);

    // Pre trade checks
    IEvaluator(evaluator).verifyMinMaxPriceChecks(price, maker);

    bool isBinaryMarket = IPerpetual(perpetual).isBinaryFutureMarket();
    _verifyTrade(tradeData, makerBalance, takerBalance, price, isBinaryMarket);

    // Bound the execution amount by the size of the maker and taker positions.
    // That clamp is this trade's only quantity bound, and it is deliberate.
    //
    // Deleveraging carries no signed user order, so the Evaluator's order-type
    // caps and its per-fill quantity grid do not apply to it -- see the scope
    // note on `Evaluator.verifySignedOrderQuantityCap`. Both are properties of
    // what a user may ask for. `amount` is derived entirely from on-chain
    // balances by an operator-gated call, and `min(maker.qPos, taker.qPos)`
    // routinely lands below `minQty` or off `stepSize` through no fault of the
    // planner. Validating it against a user-order rule would brick the exit of
    // last resort precisely when a market most needs it.
    uint128 amount = BaseMath.min(
      tradeData.quantity,
      BaseMath.min(makerBalance.qPos, takerBalance.qPos)
    );

    // Compute bankruptcy price from the maker's settled balance. Funding is
    // applied before this trader runs: a debit consumes margin first, then
    // positive unrealized profit (by moving oiOpen toward oracle notional), and
    // only the remainder is written off. Deleveraging at this price transfers
    // the remaining settled position deficit to the taker.
    // A long bankruptcy price rounds upward. Rounding it downward can create a
    // quantity-scaled deficit when the execution notional is multiplied back
    // by a large position. Shorts already round in the safe direction.
    uint128 bankruptcy = makerBalance.isPosPositive
      ? (makerBalance.oiOpen - makerBalance.margin).baseDivRoundUp(
        makerBalance.qPos
      )
      : (makerBalance.oiOpen + makerBalance.margin).baseDiv(makerBalance.qPos);

    // There is deliberately NO "taker cannot take a loss" floor here: in
    // deep deficits the profit-ranked taker eats principal, bounded by their
    // own posted margin via _applyIM's equity check below (which reverts
    // naming the taker when even that is insufficient — the off-chain
    // planner then spreads the disposal across further counterparties).

    // The bankrupt maker is deliberately exempt from the solvency check; the
    // taker is not. That asymmetry is the trailing flag.
    IMResponse memory makerResponse = _applyIM(
      maker,
      makerBalance,
      bankruptcy,
      amount,
      false /* mustBeSolvent */,
      isBinaryMarket
    );

    IMResponse memory takerResponse = _applyIM(
      taker,
      takerBalance,
      bankruptcy,
      amount,
      true /* mustBeSolvent */,
      isBinaryMarket
    );

    return
      Types.TradeResult({
        makerHash: '',
        takerHash: '',
        makerBalance: makerResponse.updatedBalance,
        takerBalance: takerResponse.updatedBalance,
        makerFundsFlow: makerResponse.fundsFlow,
        takerFundsFlow: takerResponse.fundsFlow,
        makerFee: 0,
        takerFee: 0,
        makerPnl: makerResponse.pnl,
        takerPnl: takerResponse.pnl,
        tradeQuantity: amount,
        price: bankruptcy,
        isBuy: tradeData.isBuy, // from taker's perspective
        traderFlags: TRADER_ID
      });
  }

  //===========================================================//
  //                         SETTERS
  //===========================================================//

  //===========================================================//
  //                         GETTERS
  //===========================================================//

  /**
   * @notice returns the trader flag
   */
  function getTraderFlag() public pure override returns (bytes32) {
    return TRADER_ID;
  }

  //===========================================================//
  //                      INTERNAL METHODS
  //===========================================================//

  function _applyIM(
    address maker,
    Types.PositionBalance memory balance,
    uint128 bankruptcy,
    uint128 quantity,
    bool mustBeSolvent
  ) internal pure returns (IMResponse memory) {
    return _applyIM(maker, balance, bankruptcy, quantity, mustBeSolvent, false);
  }

  function _applyIM(
    address maker,
    Types.PositionBalance memory balance,
    uint128 bankruptcy,
    uint128 quantity,
    bool mustBeSolvent,
    bool isBinaryMarket
  ) internal pure returns (IMResponse memory) {
    if (mustBeSolvent) {
      // Check the taker's full position value, rather than a per-unit value.
      // Per-unit rounding can disagree with aggregate equity at the one-wei
      // boundary. The bankrupt maker is intentionally exempt.
      int256 equity = int256(uint256(balance.margin)) +
        _positionPnl(balance, bankruptcy);
      Require.that(
        equity >= 0,
        'Cannot trade when loss exceeds margin. Please add margin',
        maker
      );
    }

    // case 2: Reducing trade

    uint128 oldQPos = balance.qPos;
    uint128 oldOiOpen = balance.oiOpen;
    uint128 oldMargin = balance.margin;
    bool preserveBinaryShortCollateralFloor = isBinaryMarket &&
      !balance.isPosPositive &&
      PositionBalanceMath.hasBinaryMaxLossCollateralFloor(balance);
    balance.qPos = balance.qPos - quantity;

    balance.oiOpen = BaseMath.mulDiv(balance.oiOpen, balance.qPos, oldQPos);
    balance.margin = BaseMath.mulDiv(balance.margin, balance.qPos, oldQPos);
    if (preserveBinaryShortCollateralFloor) {
      // Independently flooring retained oiOpen and margin can make their sum
      // one wei smaller than retained quantity, falsely turning a max-loss
      // collateralized binary short into a leveraged position. Keep that wei
      // in retained margin instead of releasing it with the closed leg.
      uint128 retainedCollateralFloor = PositionBalanceMath
        .computeBinaryShortCollateralFloor(balance);
      if (balance.margin < retainedCollateralFloor) {
        balance.margin = retainedCollateralFloor;
      }
    }

    // Account from the exact closed portions rather than multiplying rounded
    // per-unit values by quantity. This keeps realized PnL and released margin
    // tied to the actual before/after position balances.
    uint128 closedOiOpen = oldOiOpen - balance.oiOpen;
    uint128 closedMargin = oldMargin - balance.margin;
    uint128 executionNotional = quantity.baseMul(bankruptcy);
    int256 pnl = balance.isPosPositive
      ? int256(uint256(executionNotional)) - int256(uint256(closedOiOpen))
      : int256(uint256(closedOiOpen)) - int256(uint256(executionNotional));
    int256 fundsFlow = -pnl - int256(uint256(closedMargin));

    if (fundsFlow > 0) {
      // Exact closed-position accounting can exceed the proportional
      // execution equity by at most one wei. Waive that absolute dust for
      // either side: a bankrupt maker or exactly solvent taker must not need
      // otherwise-unused free collateral to complete ADL.
      require(fundsFlow == 1, 'IsolatedADL: rounding exceeds one wei');
      fundsFlow = 0;
    }

    // even if position size is zero we are setting isPosPositive to false
    // this is what default value for isPosPositive is
    balance.isPosPositive = balance.qPos > 0 ? balance.isPosPositive : false;

    //  if position is closed due reset mro to zero
    if (balance.qPos == 0) {
      balance.mro = 0;
    }

    return
      IMResponse({updatedBalance: balance, fundsFlow: fundsFlow, pnl: pnl});
  }

  /**
   * @dev verifies if the trade request is correct or not
   * @param tradeData containing TradeData (quantity, isBuy etc..)
   * @param makerBalance position balance of the bankrupt account
   * @param takerBalance position balance of the deleveraging counterparty (taker)
   * @param price oracle price
   * @param isBinaryMarket true if this is a binary future market
   */
  function _verifyTrade(
    TradeData memory tradeData,
    Types.PositionBalance memory makerBalance,
    Types.PositionBalance memory takerBalance,
    uint128 price,
    bool isBinaryMarket
  ) internal pure {
    // The order-type caps and the per-fill quantity grid do not apply to
    // deleveraging (see `trade`), but a zero request still has to be rejected:
    // both positions are non-zero below, so `amount` is zero only when the
    // request is, and a zero-quantity trade would settle as a no-op while
    // emitting a zero-quantity event. The Evaluator's `minQty` check used to
    // reject this incidentally.
    require(tradeData.quantity > 0, 'IsolatedADL: Trade quantity must be > 0');

    require(makerBalance.qPos > 0, 'IsolatedADL: Maker has zero position');

    require(takerBalance.qPos > 0, 'IsolatedADL: Taker has zero position');

    // A binary position at its max-loss collateral floor has no deficit and
    // no remaining downside inside the payout domain. Closing it belongs to
    // settlement, not ADL, regardless of the leverage it was opened with.
    require(
      !(isBinaryMarket &&
        PositionBalanceMath.hasBinaryMaxLossCollateralFloor(makerBalance)),
      'IsolatedADL: Cannot ADL fully collateralized binary position'
    );

    require(
      makerBalance.getMarginRatioWithBinaryCheck(price, isBinaryMarket) <= 0,
      'IsolatedADL: Cannot deleverage since maker is not underwater'
    );

    require(
      takerBalance.getMarginRatioWithBinaryCheck(price, isBinaryMarket) > 0,
      'IsolatedADL: Cannot deleverage since taker is underwater'
    );

    require(
      !tradeData.allOrNothing || makerBalance.qPos >= tradeData.quantity,
      'IsolatedADL: allOrNothing is set and maker position is < quantity'
    );
    require(
      takerBalance.isPosPositive != makerBalance.isPosPositive,
      'IsolatedADL: Taker and maker can not have same side positions'
    );
    require(
      !tradeData.allOrNothing || takerBalance.qPos >= tradeData.quantity,
      'IsolatedADL: allOrNothing is set and taker position is < quantity'
    );
    require(
      tradeData.isBuy == makerBalance.isPosPositive,
      "IsolatedADL: deleveraging must not increase maker's position size"
    );
  }

  function _positionPnl(
    Types.PositionBalance memory balance,
    uint128 price
  ) internal pure returns (int256) {
    int256 notional = int256(uint256(balance.qPos.baseMul(price)));
    return
      balance.isPosPositive
        ? notional - int256(uint256(balance.oiOpen))
        : int256(uint256(balance.oiOpen)) - notional;
  }
}
