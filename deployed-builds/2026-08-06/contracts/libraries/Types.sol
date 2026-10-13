// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;
import {TypedSignature} from "./TypedSignature.sol";

library Types {
    //
    // STRUCTS
    //

    /**
     * @dev A funding index snapshot: Perpetual's market-wide `globalIndex`
     *  (and the frozen `delistIndex`). An account's own baseline is stored as
     *  `PackedAccountState.fundingIndex`; settlement charges or credits the
     *  difference between the two, times the position size.
     */
    struct Index {
        uint128 timestamp;
        int256 value;
    }

    /**
     * @dev Used to represent user's position on chain.
     *  This struct is used in memory throughout the codebase for computation.
     *  Storage uses PackedAccountState (2 slots) for on-chain persistence.
     */
    struct PositionBalance {
        // is position long/short buy/sell
        bool isPosPositive;
        // margin ratio at open (1e18 scale, computed from leverage: 1e18 / leverage)
        uint128 mro;
        // quantity of asset e.g. DOT,BTC etc..
        uint128 qPos;
        // margin/collateral locked in position
        uint128 margin;
        // funding-adjusted position cost basis (entry notional)
        uint128 oiOpen;
    }

    /**
     * @dev 2-slot packed on-chain storage for per-account position + funding state.
     *  Replaces separate positionBalances and localIndexes mappings.
     *  Slot 0: flags(8) + leverage(16) + qPos(112) + fundingIndex(120) = 256 bits
     *  Slot 1: margin(128) + oiOpen(128) = 256 bits
     */
    struct PackedAccountState {
        // Slot 0
        uint8   flags;        // bit 0 = isPosPositive
        uint16  leverage;     // whole-number leverage, 1e18 / mro (1..65535); 0 when mro is 0.
                              // A flat account can keep a nonzero value.
        uint112 qPos;         // position quantity (e18 scale)
        int120  fundingIndex; // local funding baseline index value

        // Slot 1
        uint128 margin;       // isolated margin/collateral (e18 scale)
        uint128 oiOpen;       // funding-adjusted position cost basis (e18 scale)
    }

    /**
     * @dev Caches commonly used variable across the protocol, to save gas
     */
    struct Context {
        // current oracle price
        uint128 price;
        // funding rate to be applied
        int256 fundingRate;
        // global index (used for computing settlement amount)
        Index index;
    }

    /**
     * @dev Returned response from contracts implementing ITrader interface
     */
    struct TradeResult {
        // maker order hash
        bytes32 makerHash;
        // taker order hash
        bytes32 takerHash;
        // maker's updated positon baalnce after trade
        PositionBalance makerBalance;
        // taker's updated positon baalnce after trade
        PositionBalance takerBalance;
        // funds flow for maker (+ive means from bank -ive means to bank)
        int256 makerFundsFlow;
        // funds flow for taker (+ive means from bank -ive means to bank)
        int256 takerFundsFlow;
        // quantity of asset traded
        uint128 tradeQuantity;
        // price at which trade took place
        uint128 price;
        // fee paid by maker
        uint128 makerFee;
        // fee paid by taker
        uint128 takerFee;
        // pnl of maker
        int256 makerPnl;
        // pnl of taker
        int256 takerPnl;
        // from taker's perspective
        bool isBuy;
        // per-fill flag: the trader's getTraderFlag() value for an ordinary fill,
        // or IsolatedTrader's LIQUIDATION_TRADER_ID (2, forced taker) or
        // DUAL_LIQUIDATION_TRADER_ID (4, both sides forced) for a book-side
        // forced liquidation fill; Perpetual grants the liquidation margin
        // allowance from it
        bytes32 traderFlags;
    }

    /**
     * @dev status set by guardian for controlled methods
     */
    enum GuardianStatus {
        ALLOWED,
        NOT_ALLOWED
    }

    /**
     * @dev What an operator may do for a system account in ONE market (audit
     * issue #38). Ordinary user subaccounts do not use this: their approval
     * stays global, as it always was.
     *
     * NONE is zero on purpose. An unwritten entry must deny, so a market nobody
     * explicitly granted is closed rather than open — which is the whole point
     * of the issue: a vault child trader could previously sign in any market
     * because one global approval covered them all.
     *
     * REDUCE_ONLY is the wind-down state. It permits reducing or closing
     * exposure, adding margin, and adjustLeverage at the same or a lower
     * leverage; it forbids growing the position, flipping to the other side,
     * removeMargin / removeMarginUpTo, and raising leverage. It is distinct
     * from NONE so the operator can still wind the position down once the
     * market stops taking new risk. Permission does not affect vault
     * valuation: LiquidityVault values a tracked pair's position under any
     * permission, and the pair can be untracked only once that position is
     * zero.
     */
    enum MarketPermission {
        NONE,
        REDUCE_ONLY,
        ACTIVE
    }

    /**
     * @dev Signed trigger condition for conditional (stop / take-profit)
     * orders — audit issue #50. The condition is part of the signed order
     * struct, so the settlement operator cannot choose or invert the
     * direction after signing.
     *
     * The order struct carries this as `uint8` (not the enum type) so that
     * `abi.decode` of an unknown value does not revert with empty data before
     * per-order validation can attribute the fault; `IsolatedTrader`
     * explicitly rejects any value above `PRICE_AT_OR_BELOW` ('P81'), and a
     * forced liquidation order may not carry any trigger condition ('P84').
     *
     * Values 3+ are RESERVED for future authenticated mark-price variants
     * (e.g. MARK_AT_OR_ABOVE / MARK_AT_OR_BELOW once an authenticated
     * on-chain mark price exists). Because unknown values are rejected —
     * never treated as NONE — those variants can be added by extending the
     * validation bound in a later upgrade WITHOUT another order-signature
     * cutover: the field is already signed.
     */
    enum TriggerCondition {
        // No trigger. `triggerPrice` must be zero.
        NONE,
        // Execute only while oraclePrice >= triggerPrice - band, where band is
        // oraclePrice times Evaluator.triggerBandFor(the order's isBuy); a band
        // at or above triggerPrice always passes. `triggerPrice` > 0.
        PRICE_AT_OR_ABOVE,
        // Execute only while oraclePrice <= triggerPrice + band (same band).
        // `triggerPrice` > 0.
        PRICE_AT_OR_BELOW
    }
}
