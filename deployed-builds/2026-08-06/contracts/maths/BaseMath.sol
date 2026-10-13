// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

/**
 * @title BaseMath
 * @notice 1e18 fixed-point helpers shared by every MNX contract.
 * @dev The helpers that compute a wide result and return `uint128` --
 * `baseMul`, `baseDiv`, `baseDivRoundUp`, `baseMulRoundUp`, `mulDiv`,
 * `absolute`, and `toPositive` -- narrow with `SafeCast.toUint128`. A result
 * outside `[0, type(uint128).max]` reverts with
 * `SafeCast.SafeCastOverflowedUintDowncast(128, result)` instead of silently
 * keeping the low 128 bits. Division by zero still reverts with Solidity's
 * arithmetic panic (0x12), except `baseDivRoundUp(0, 0)`, which returns 0
 * through its zero-value shortcut. `absolute` accepts the whole `int256` range
 * including `type(int256).min` (which reverts on the cast, not on a negation).
 */
library BaseMath {
    // 1e18 uint.
    uint128 internal constant BASE_UINT = 10**18;

    // 1e18 int.
    int256 internal constant BASE_INT = 10**18;

    // Protocol-wide maximum trade fee: 25% of notional, in 1e18 fixed point.
    // Single source of truth shared by Perpetual's default maker/taker fee
    // setters and IsolatedTrader's whitelisted per-trader fee overrides, so a
    // whitelist entry can never exceed the cap advertised for default fees.
    uint128 internal constant MAX_TRADE_FEE = 0.25e18;

    /**
     * @dev Getter for BASE_INT.
     */
    function baseInt() internal pure returns (int256) {
        return BASE_INT;
    }

    /**
     * @dev Getter for BASE_UINT.
     */
    function baseUInt() internal pure returns (uint128) {
        return BASE_UINT;
    }

    /**
     * @dev Multiplies a value by a base value (result is rounded down).
     */
    function baseMul(uint128 value, uint128 baseValue)
        internal
        pure
        returns (uint128)
    {
        return
            SafeCast.toUint128(
                (uint256(value) * uint256(baseValue)) / BASE_UINT
            );
    }

    /**
     * @dev Multiplication by a base value with the result truncated toward
     * zero (a negative result rounds up)
     */
    function baseMul(int256 value, int256 baseValue)
        internal
        pure
        returns (int256)
    {
        return (value * baseValue) / BASE_INT;
    }

    /**
     * @dev Multiplication by a base value with the result truncated toward
     * zero (a negative result rounds up)
     */
    function baseMul(uint128 value, int256 baseValue)
        internal
        pure
        returns (int256)
    {
        return (int256(uint256(value)) * baseValue) / BASE_INT;
    }

    /**
     * @dev Division by a base value with the result rounded down
     */
    function baseDiv(uint128 value, uint128 baseValue)
        internal
        pure
        returns (uint128)
    {
        return
            SafeCast.toUint128(
                (uint256(value) * uint256(BASE_UINT)) / uint256(baseValue)
            );
    }

    /**
     * @dev Division by a base value with the result rounded up.
     */
    function baseDivRoundUp(uint128 value, uint128 baseValue)
        internal
        pure
        returns (uint128)
    {
        if (value == 0) {
            return 0;
        }
        // Apply the round-up `+ 1` in uint256 so an out-of-range rounded result
        // reaches the same checked narrowing as the other wide-result helpers.
        return
            SafeCast.toUint128(
                ((uint256(value) * uint256(BASE_UINT)) - 1) /
                    uint256(baseValue) +
                    1
            );
    }

    /**
     * @dev Divide a value by a base value (result is truncated toward zero, so
     * a negative result rounds up).
     */
    function baseDiv(int256 value, int256 baseValue)
        internal
        pure
        returns (int256)
    {
        return (value * BASE_INT) / baseValue;
    }

    /**
     * @dev Multiplies a value by a base value (result is rounded up).
     */
    function baseMulRoundUp(uint128 value, uint128 baseValue)
        internal
        pure
        returns (uint128)
    {
        if (value == 0 || baseValue == 0) {
            return 0;
        }
        // As in baseDivRoundUp, keep the round-up `+ 1` in uint256 so an
        // out-of-range result reaches the checked narrowing below.
        return
            SafeCast.toUint128(
                ((uint256(value) * uint256(baseValue)) - 1) / BASE_UINT + 1
            );
    }

    /**
     * @dev Multiplies two unscaled values then divides, rounding down once.
     * Both inputs are uint128, so their product fits in uint256.
     */
    function mulDiv(uint128 value, uint128 multiplier, uint128 divisor)
        internal
        pure
        returns (uint128)
    {
        return
            SafeCast.toUint128(
                (uint256(value) * uint256(multiplier)) / uint256(divisor)
            );
    }

    /**
     * @dev Returns absolute of the number
     */
    function absolute(int256 number) internal pure returns (uint128) {
        if (number >= 0) {
            return SafeCast.toUint128(uint256(number));
        }
        // Negating type(int256).min overflows int256, so build the magnitude
        // from -(number + 1) -- always representable -- and add the missing 1
        // in uint256. Out-of-range magnitudes then revert on the cast rather
        // than on an arithmetic panic.
        return SafeCast.toUint128(uint256(-(number + 1)) + 1);
    }

    /**
     * @dev Returns the maximum between a and b.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the minimum between a and b.
     */
    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    /**
     * @dev returns max(number, 0) as uint128; reverts above type(uint128).max
     */
    function toPositive(int256 number) internal pure returns (uint128) {
        return number >= 0 ? SafeCast.toUint128(uint256(number)) : 0;
    }

    /**
     * @dev Returns ceil(a,m)
     */
    function ceil(uint128 a, uint128 m) internal pure returns (uint128) {
        return ((a + m - 1) / m) * m;
    }
}
