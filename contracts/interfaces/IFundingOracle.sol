// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";

interface IFundingOracle {
    /**
     * @notice Starts funding oracle's 1st window at specified time
     * @param _timestamp time at which funding will start
     */
    function startFunding(uint128 _timestamp) external;

    /**
     * @notice Stops funding oracle
     */
    function stopFunding() external;

    /**
     * @notice The funder's half of a two-sided handover: confirms this oracle
     * is paired with the calling Perpetual and that its funding schedule is
     * clean enough to adopt.
     * @dev Called by Perpetual during a funder handover. Reverts unless the
     * caller is the provider this oracle already names, so the two contracts
     * cannot end up pointing at each other only from one side.
     */
    function confirmProviderPairing() external;

    /**
     * @notice Installs the rate for the on-going window while on-chain
     * funding is the allowed mode. Can only be invoked by the funding rate
     * provider.
     * @param _fundingRate the rate for one whole funding window, in the same
     * signed e18 representation as {maxFunding}. Over-cap values revert.
     */
    function setFundingRate(int256 _fundingRate) external;

    /**
     * @notice Updates funding rate status of this market
     * @dev Must be called by the Guardian
     * @param _newStatus status of funding rate for this market. ALLOWED selects
     * the on-chain mode ({setFundingRate}); any other status selects the
     * off-chain mode ({setOffChainFundingRate}). The rate is supplied off-chain
     * in both modes.
     */
    function setFundingRateStatus(Types.GuardianStatus _newStatus) external;

    /**
     * @notice Installs the rate for the on-going window while the off-chain
     * funding mode is active. Can only be invoked by the funding rate provider.
     * @param _offchainFundingRate the rate for one whole funding window, in
     * the same signed e18 representation as {maxFunding}. Over-cap values
     * revert.
     */
    function setOffChainFundingRate(int256 _offchainFundingRate) external;

    /**
     * Returns true while the on-chain funding mode (status ALLOWED) is active.
     */
    function isFundingRateAllowed() external view returns (bool);

    /**
     * @notice returns the funding rate provider
     */
    function provider() external view returns (address);

    /**
     * @notice returns the Guardian contract allowed to set funding status
     */
    function guardianContract() external view returns (address);

    /**
     * @notice returns current funding rate
     */
    function getFundingRate() external view returns (int256);

    /**
     * @notice returns the maximum allowed funding rate per hour
     */
    function maxFunding() external view returns (uint128);

    /**
     * @notice Length of one funding window in seconds.
     * @dev Paired with {maxFunding} to derive the per-second rate ceiling:
     * `maxFunding` is a per-window cap and the stored rate is per second.
     * Exposed so callers do not have to restate the window length.
     */
    function FUNDING_RATE_WINDOW() external view returns (uint128);

    /**
     * @notice Returns true once binary-market funding is locked off.
     */
    function binaryMarketFundingLocked() external view returns (bool);
}
