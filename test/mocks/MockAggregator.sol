// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @notice 테스트용 Chainlink 피드
contract MockAggregator {
    uint8 public immutable decimals;

    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setRoundData(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

/// @notice 바닥과 천장 값이 있는 테스트용 피드
contract MockAggregatorWithBounds is MockAggregator {
    int192 public immutable minAnswer;
    int192 public immutable maxAnswer;

    constructor(uint8 decimals_, int192 minAnswer_, int192 maxAnswer_) MockAggregator(decimals_) {
        minAnswer = minAnswer_;
        maxAnswer = maxAnswer_;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }
}
