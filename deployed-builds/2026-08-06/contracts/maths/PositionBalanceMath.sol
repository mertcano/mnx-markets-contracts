// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {BaseMath} from "../maths/BaseMath.sol";
import {Types} from "../libraries/Types.sol";

library PositionBalanceMath {
    using BaseMath for uint128;

    /// @dev 1 wei in e18 scale - the smallest positive value for binary market minPrice
    uint128 internal constant BINARY_MIN_PRICE = 1;
    /// @dev 1.0 in e18 scale - the maxPrice for binary markets
    uint128 internal constant BINARY_MAX_PRICE = 1e18;

    /**
     * @dev Check if a market is a binary-bounded market based on price bounds and funding rate
     * Binary markets have:
     * - minPrice == 1 (1 wei in e18)
     * - maxPrice == 1e18 (1.0)
     * - maxFundingRate == 0
     * @param minPrice minimum allowed order price from Evaluator
     * @param maxPrice maximum allowed order price from Evaluator
     * @param maxFundingRate maximum funding rate from FundingOracle
     */
    function isBinaryBoundedMarket(
        uint128 minPrice,
        uint128 maxPrice,
        uint128 maxFundingRate
    ) internal pure returns (bool) {
        return minPrice == BINARY_MIN_PRICE &&
               maxPrice == BINARY_MAX_PRICE &&
               maxFundingRate == 0;
    }

    function isOneXPosition(Types.PositionBalance memory positionBalance) internal pure returns (bool) {
        return positionBalance.mro == BaseMath.baseUInt();
    }

    /**
     * @dev Max loss collateral floor for a binary short: qPos - oiOpen.
     */
    function computeBinaryShortCollateralFloor(
        Types.PositionBalance memory positionBalance
    ) internal pure returns (uint128) {
        if (positionBalance.isPosPositive || positionBalance.qPos <= positionBalance.oiOpen) {
            return 0;
        }
        return positionBalance.qPos - positionBalance.oiOpen;
    }

    /**
     * @dev Max loss collateral floor for a binary position:
     * - Long: oiOpen
     * - Short: qPos - oiOpen
     */
    function computeBinaryMaxLossCollateralFloor(
        Types.PositionBalance memory positionBalance
    ) internal pure returns (uint128) {
        return positionBalance.isPosPositive
            ? positionBalance.oiOpen
            : computeBinaryShortCollateralFloor(positionBalance);
    }

    /**
     * @dev Returns true if a binary position has enough margin to cover max loss.
     */
    function hasBinaryMaxLossCollateralFloor(
        Types.PositionBalance memory positionBalance
    ) internal pure returns (bool) {
        return positionBalance.margin >= computeBinaryMaxLossCollateralFloor(positionBalance);
    }

    /**
     * @dev Classifies a before -> after position transition as risk-increasing.
     *
     * One definition shared by every consumer (Perpetual's margin-health check
     * and Evaluator's open-notional cap check) so the two can never disagree
     * about what "increases risk" means.
     *
     * Risk increases when the account takes on more exposure than it had:
     * - a brand-new position (there was nothing before),
     * - absolute quantity grows,
     * - the position flips to the opposite side (a fresh opposite-side
     *   position, regardless of how large it is),
     * - or, at unchanged quantity and side, the stored margin requirement
     *   `mro` falls, which is the account selecting higher leverage.
     *
     * Risk does NOT increase on a full close or a same-side quantity
     * reduction. The ordering there is deliberate: the quantity comparison is
     * made BEFORE the `mro` comparison, so a same-side reduction stays a
     * reduction even if it also lowers `mro`.
     *
     * That ordering is defence in depth rather than a live requirement.
     * `IsolatedTrader._verifyOrderLeverage` requires an order's leverage to
     * equal the stored `mro` whenever `qPos > 0`, so no fill can change `mro`
     * on a live position and the two orderings agree today. It matters if that
     * invariant is ever relaxed: a reduce-only exit must not become
     * unexecutable for an under-margined account just because the order carried
     * a different leverage. A lower `mro` still cannot be used to escalate —
     * the next transition that actually grows or flips is measured against the
     * new `mro` and must satisfy the full requirement on its own.
     *
     * @param beforeBalance position before the update
     * @param afterBalance position after the update
     */
    function isRiskIncreasingTransition(
        Types.PositionBalance memory beforeBalance,
        Types.PositionBalance memory afterBalance
    ) internal pure returns (bool) {
        if (afterBalance.qPos == 0) {
            return false;
        }
        if (beforeBalance.qPos == 0) {
            return true;
        }
        if (afterBalance.qPos > beforeBalance.qPos) {
            return true;
        }
        if (afterBalance.isPosPositive != beforeBalance.isPosPositive) {
            return true;
        }
        if (afterBalance.qPos < beforeBalance.qPos) {
            return false;
        }
        return afterBalance.mro < beforeBalance.mro;
    }

    /**
     * @dev returns margin ratio of position
     * @param positionBalance position of account on perpetual
     * @param price current oracle price
     */
    function getMarginRatio(
        Types.PositionBalance memory positionBalance,
        uint128 price
    ) internal pure returns (int256) {
        int256 marginRatio = 0;
        if (positionBalance.isPosPositive) {
            int256 balance = int256(
                (uint256(price) * uint256(positionBalance.qPos)) /
                    BaseMath.baseUInt()
            );
            int256 debt = int256(int128(positionBalance.oiOpen)) -
                int256(int128(positionBalance.margin));

            marginRatio = balance > 0
                ? BaseMath.baseInt() - ((debt * BaseMath.baseInt()) / balance)
                : (debt > 0 ? -BaseMath.baseInt() : BaseMath.baseInt());
        } else {
            int256 debt = int256(int128(positionBalance.oiOpen)) +
                int256(int128(positionBalance.margin));

            int256 balance = (int256(int128(price)) *
                int256(int128(positionBalance.qPos))) / BaseMath.baseInt();

            marginRatio = balance > 0
                ? ((debt * BaseMath.baseInt()) / balance) - BaseMath.baseInt()
                : BaseMath.baseInt();
        }

        return marginRatio;
    }

    /**
     * @dev returns the oracle-basis risk notional of a position:
     * - Binary short: remaining payout exposure, `qPos - qPos * price`. A short
     *   settles by paying `qPos` at most, so once the outcome price is near the
     *   upper payout bound almost nothing is left to lose.
     * - Everything else (all longs, and shorts on non-binary markets): spot
     *   notional, `qPos * price`.
     * Exposed separately so risk thresholds measured in collateral (rather than
     * as a ratio) use the same basis as the margin ratio instead of always
     * assuming spot notional.
     * @param positionBalance position of account on perpetual
     * @param price current oracle price
     * @param isBinaryMarket true if this is a binary future market (from Perpetual.isBinaryFutureMarket())
     */
    function getRiskNotional(
        Types.PositionBalance memory positionBalance,
        uint128 price,
        bool isBinaryMarket
    ) internal pure returns (uint128) {
        uint128 currentValue = positionBalance.qPos.baseMul(price);

        if (isBinaryMarket && !positionBalance.isPosPositive) {
            return positionBalance.qPos > currentValue
                ? positionBalance.qPos - currentValue
                : 0;
        }

        return currentValue;
    }

    /**
     * @dev returns margin ratio of position, with special handling for binary markets
     * For 1x positions in binary-bounded markets with max-loss collateral,
     * MR is always 100% (fully collateralized).
     * @param positionBalance position of account on perpetual
     * @param price current oracle price
     * @param isBinaryMarket true if this is a binary future market (from Perpetual.isBinaryFutureMarket())
     */
    function getMarginRatioWithBinaryCheck(
        Types.PositionBalance memory positionBalance,
        uint128 price,
        bool isBinaryMarket
    ) internal pure returns (int256) {
        if (
            isBinaryMarket &&
            isOneXPosition(positionBalance) &&
            hasBinaryMaxLossCollateralFloor(positionBalance)
        ) {
            return BaseMath.baseInt();
        }

        if (isBinaryMarket && !positionBalance.isPosPositive) {
            int256 equity = int256(uint256(positionBalance.margin)) +
                int256(uint256(positionBalance.oiOpen)) -
                int256(uint256(positionBalance.qPos.baseMul(price)));

            if (equity < 0) {
                return positionBalance.margin > 0
                    ? (equity * BaseMath.baseInt()) / int256(uint256(positionBalance.margin))
                    : -BaseMath.baseInt();
            }

            uint128 riskNotional = getRiskNotional(
                positionBalance,
                price,
                true
            );

            return riskNotional > 0
                ? (equity * BaseMath.baseInt()) / int256(uint256(riskNotional))
                : BaseMath.baseInt();
        }

        // Default to standard margin ratio calculation
        return getMarginRatio(positionBalance, price);
    }

    /**
     * @dev returns average entry price for position
     * @param positionBalance account's position
     */
    function getAverageEntryPrice(Types.PositionBalance memory positionBalance)
        internal
        pure
        returns (uint128)
    {
        return
            positionBalance.oiOpen == 0
                ? 0
                : BaseMath.baseDiv(
                    positionBalance.oiOpen,
                    positionBalance.qPos
                );
    }
}
