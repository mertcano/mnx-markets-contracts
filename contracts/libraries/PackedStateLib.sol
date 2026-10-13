// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from "./Types.sol";
import {BaseMath} from "../maths/BaseMath.sol";

/**
 * @title PackedStateLib
 * @dev Converts between PackedAccountState (2-slot storage) and the in-memory
 *      PositionBalance + fundingIndex representation used throughout the codebase.
 */
library PackedStateLib {
    uint8 internal constant FLAG_IS_POS_POSITIVE = 1;

    function load(
        Types.PackedAccountState storage packed
    ) internal view returns (Types.PositionBalance memory balance, int256 fundingIndex) {
        balance.isPosPositive = (packed.flags & FLAG_IS_POS_POSITIVE) != 0;
        balance.mro = packed.leverage > 0
            ? BaseMath.baseUInt() / uint128(packed.leverage)
            : 0;
        balance.qPos = uint128(packed.qPos);
        balance.margin = packed.margin;
        balance.oiOpen = packed.oiOpen;
        fundingIndex = int256(packed.fundingIndex);
    }

    function store(
        Types.PackedAccountState storage packed,
        Types.PositionBalance memory balance,
        int256 fundingIndex
    ) internal {
        uint16 leverage;
        if (balance.mro > 0) {
            uint128 lev = BaseMath.baseUInt() / balance.mro;
            require(lev <= type(uint16).max, "PackedState: leverage overflow");
            leverage = uint16(lev);
        }

        require(balance.qPos <= type(uint112).max, "PackedState: qPos overflow");
        require(
            fundingIndex >= type(int120).min && fundingIndex <= type(int120).max,
            "PackedState: fundingIndex overflow"
        );

        packed.flags = balance.isPosPositive ? FLAG_IS_POS_POSITIVE : 0;
        packed.leverage = leverage;
        packed.qPos = uint112(balance.qPos);
        packed.fundingIndex = int120(fundingIndex);
        packed.margin = balance.margin;
        packed.oiOpen = balance.oiOpen;
    }
}
