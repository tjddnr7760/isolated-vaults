// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chainlink 가격 피드 인터페이스
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Chainlink 가격 한도 조회 인터페이스
interface IAggregatorBounds {
    function aggregator() external view returns (address);

    function minAnswer() external view returns (int192);

    function maxAnswer() external view returns (int192);
}
