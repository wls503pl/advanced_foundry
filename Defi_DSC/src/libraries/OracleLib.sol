// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a price is stale, the function will revert and render the DSCEngin unusable.
 * (We want the DSCEngine to freeze if prices become stale)
 */
library OracleLib {
    // Error thrown when oracle price data is outdated
    error OracleLib__StalePrice();

    // Maximum allowed time (3 hours) before price data is considered stale
    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Fetches latest price data from Chainlink oracle and validates freshness
     * @param priceFeed The Chainlink AggregatorV3Interface contract
     * @return roundId The round ID of the price data
     * @return answer The latest price answer
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the price was last updated
     * @return answeredInRound The round ID in which the answer was computed
     * @dev Reverts if price data is older than TIMEOUT (3 hours)
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        // Get latest round data from the oracle
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // Calculate how many seconds have passed since the last price update
        uint256 secondsSince = block.timestamp - updatedAt;

        // Revert if price data is stale (older than 3 hours)
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        // Return all price data if it's fresh
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
