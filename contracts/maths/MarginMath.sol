// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";
import {BaseMath} from "../maths/BaseMath.sol";
import {IMarginMath} from "../interfaces/IMarginMath.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title Margin Math
 * @author MNX Markets <help@mnx.fi>
 * @notice Computes margin to be moved out of or into the user position under different
 * circumstances
 */
contract MarginMath is IMarginMath, Initializable {
    using BaseMath for uint128;
    using BaseMath for int256;

    function initialize() public initializer {}

    /**
     * @dev returns margin left in an account's position at the time of position closure
     * post perpetual delisting
     *
     * NOT CALLED BY THE CURRENT PERPETUAL. As of audit issue #40, Perpetual's
     * delist close computes the gross claim inline from `_positionEquity` —
     * equity at the frozen `delistingPrice`, floored at zero — so the
     * pre-close `accountFundingAdjustedEquity` view and the gross claim run
     * one formula instead of two copies that could drift. This function is
     * retained on the live shared proxy for
     * application binary interface stability; do not treat it as the
     * settlement source of truth, and do not reintroduce a caller without
     * reconciling it against `Perpetual._positionEquity`.
     *
     * @param _positionBalance account's position on perpetual
     * @param _delistingPrice price of oracle for delisting
     * @param _perpetualBalance amount of balance, collateral perpetual has
     */
    function getMarginLeft(
        Types.PositionBalance memory _positionBalance,
        uint128 _delistingPrice,
        uint128 _perpetualBalance
    ) public pure override returns (uint128) {
        // Settlement value = margin + PnL at the delisting price, with PnL
        // computed directly from quantity (qPos * P - oiOpen), matching
        // Perpetual._positionPnl. Routing through average entry price
        // (oiOpen * P / pPos) divides by zero for edge-case positions whose
        // oiOpen is zero while qPos stays positive; those must still settle
        // at delist instead of bricking the close.
        uint128 notional = _positionBalance.qPos.baseMul(_delistingPrice);
        uint128 marginLeft;

        if (_positionBalance.isPosPositive) {
            marginLeft = BaseMath.toPositive(
                int256(uint256(_positionBalance.margin)) +
                    int256(uint256(notional)) -
                    int256(uint256(_positionBalance.oiOpen))
            );
        } else {
            marginLeft = BaseMath.toPositive(
                int256(uint256(_positionBalance.margin)) +
                    int256(uint256(_positionBalance.oiOpen)) -
                    int256(uint256(notional))
            );
        }

        // if not enough balance in perpetual, margin left is equal to total
        // amount left in perpetual
        marginLeft = BaseMath.min(marginLeft, _perpetualBalance);

        return marginLeft;
    }

    /**
     * @dev returns the target margin required when adjusting leverage
     * @param _positionBalance account's position on perpetual
     * @param _leverage new leverage
     * @param _oraclePrice price of the asset
     */
    function getTargetMargin(
        Types.PositionBalance memory _positionBalance,
        uint128 _leverage,
        uint128 _oraclePrice
    ) public pure override returns (uint128) {
        uint128 targetMargin = 0;

        if (_positionBalance.isPosPositive) {
            // if long
            targetMargin = BaseMath.absolute(
                BaseMath.max(
                    0,
                    (
                        int256(
                            uint256(
                                _positionBalance
                                    .qPos
                                    .baseMul(_oraclePrice)
                                    .baseDivRoundUp(_leverage)
                            )
                        )
                    ) -
                        int256(
                            uint256(_positionBalance.qPos.baseMul(_oraclePrice))
                        ) +
                        int256(uint256(_positionBalance.oiOpen))
                )
            );
        } else {
            // if short
            targetMargin = BaseMath.absolute(
                BaseMath.max(
                    0,
                    (
                        int256(
                            uint256(
                                _positionBalance
                                    .qPos
                                    .baseMul(_oraclePrice)
                                    .baseDivRoundUp(_leverage)
                            )
                        )
                    ) +
                        int256(
                            uint256(_positionBalance.qPos.baseMul(_oraclePrice))
                        ) -
                        int256(uint256(_positionBalance.oiOpen))
                )
            );
        }

        return targetMargin;
    }

    /**
     * @dev returns the maximum removeable amount of margin from an accounts position
     * before the account becomes under collat
     * @param _positionBalance account's position on perpetual
     * @param _oraclePrice price of the asset
     */
    function getMaxRemoveableMargin(
        Types.PositionBalance memory _positionBalance,
        uint128 _oraclePrice
    ) public pure override returns (uint128) {
        uint128 maxRemovableAmount = 0;

        if (_positionBalance.isPosPositive) {
            maxRemovableAmount = BaseMath.min(
                _positionBalance.margin,
                BaseMath.absolute(
                    BaseMath.max(
                        0,
                        int256(uint256(_positionBalance.margin)) -
                            int256(uint256(_positionBalance.oiOpen)) +
                            int256(
                                uint256(
                                    _positionBalance.qPos.baseMul(
                                        _oraclePrice.baseMul(
                                            BaseMath.baseUInt() -
                                                _positionBalance.mro
                                        )
                                    )
                                )
                            )
                    )
                )
            );
        } else {
            // if short
            maxRemovableAmount = BaseMath.min(
                _positionBalance.margin,
                BaseMath.absolute(
                    BaseMath.max(
                        0,
                        int256(
                            uint256(
                                _positionBalance.margin +
                                    _positionBalance.oiOpen
                            )
                        ) -
                            int256(
                                uint256(
                                    _positionBalance.qPos.baseMul(
                                        _oraclePrice.baseMul(
                                            BaseMath.baseUInt() +
                                                _positionBalance.mro
                                        )
                                    )
                                )
                            )
                    )
                )
            );
        }

        return maxRemovableAmount;
    }
}
