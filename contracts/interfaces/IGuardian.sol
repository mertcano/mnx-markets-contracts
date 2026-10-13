// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";

interface IGuardian {
    /**
     * @dev Callable only by the guardian operator
     * @param _perpetual represents address of Perpetual contract for a market
     * @param _newStatus status of trading for this market. If not allowed then no new trades can be performed
     */
    function setTradingStatus(
        address _perpetual,
        Types.GuardianStatus _newStatus
    ) external;

    /**
     * @dev Callable by the guardian operator or the funding-status operator
     * @param _fundingOracle represents address of FundingOracle contract for a market
     * @param _newStatus ALLOWED selects the market's on-chain funding mode; any
     * other status selects the off-chain mode. The rate is supplied off-chain in
     * both modes.
     */
    function setFundingRateStatus(
        address _fundingOracle,
        Types.GuardianStatus _newStatus
    ) external;

    /**
     * @dev Must be called by the owner
     * @param _newGuardianOperator the hot emergency key allowed to pause and
     * resume trading and withdrawals. Must be non-zero.
     */
    function setGuardianOperator(address _newGuardianOperator) external;

    /**
     * @dev Must be called by the owner
     * @param _newOperator operator allowed to toggle funding status only. The
     * zero address disables the separate funding-only role; the guardian
     * operator can still toggle funding status.
     */
    function setFundingStatusOperator(address _newOperator) external;

    /**
     * @dev Must be called by the owner. Moves both emergency roles atomically
     * so a handoff cannot half-apply and leave the retired key holding one of
     * them.
     * @param _newGuardianOperator the new guardian operator. Must be non-zero.
     * @param _newFundingStatusOperator the new funding-status operator. Zero
     * disables the separate funding-only role.
     */
    function setEmergencyRoles(
        address _newGuardianOperator,
        address _newFundingStatusOperator
    ) external;

    /**
     * @dev Callable only by the guardian operator
     * @param _marginBank represents address of the MarginBank contract
     * @param _newStatus ALLOWED enables withdrawals from that bank and NOT_ALLOWED
     * disables them; the status is bank-wide, not per market
     */
    function setWithdrawalStatus(
        address _marginBank,
        Types.GuardianStatus _newStatus
    ) external;

    /**
     * @param _marketAddress address of the Perpetual contract for a given market, returns true
     * while its Guardian trading status is ALLOWED. NOT_ALLOWED blocks every trade, including
     * liquidations; true alone does not mean trades are accepted (a delisted or not-yet-started
     * market still rejects them)
     */
    function isTradingAllowed(address _marketAddress)
        external
        view
        returns (bool);

    /**
     * @param _marketAddress address of the FundingOracle contract for a given market, returns true
     * while the market is in the on-chain funding mode (status ALLOWED)
     */
    function isFundingRateAllowed(address _marketAddress)
        external
        view
        returns (bool);

    /**
     * @param _marketAddress address of the MarginBank contract, returns true if
     * that bank's withdrawal status (bank-wide, not per market) is ALLOWED else false
     */
    function isWithdrawalAllowed(address _marketAddress)
        external
        view
        returns (bool);

    /**
     * returns the hot emergency key: pauses/resumes trading and withdrawals,
     * and is also accepted by the funding-status check
     */
    function guardianOperator() external view returns (address);

    /**
     * returns the address allowed to toggle funding status only, or the zero
     * address when the separate funding-only role is disabled
     */
    function fundingStatusOperator() external view returns (address);
}
