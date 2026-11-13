// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AggregatorV3Interface, IAggregatorBounds} from "./interfaces/AggregatorV3Interface.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @notice Chainlink 가격을 검사해서 시장에 넘기는 어댑터
contract OracleAdapter is IOracle {
    /* ERRORS */

    error ZeroAddress();

    error ZeroStaleness();

    error InvalidBounds(int256 minAnswer, int256 maxAnswer);

    error UnsupportedDecimals();

    error NonPositivePrice(int256 answer);

    error PriceOutOfBounds(int256 answer);

    error StalePrice(uint256 updatedAt);

    /* CONSTANTS */

    uint256 private constant PRICE_SCALE_DECIMALS = 36;

    /* IMMUTABLES */

    address public immutable LOAN_TOKEN;

    address public immutable COLLATERAL_TOKEN;

    AggregatorV3Interface public immutable FEED;

    /// @notice 피드 가격에 곱하는 배율
    uint256 public immutable SCALE_FACTOR;

    /// @notice 가격 허용 시간 (초)
    uint256 public immutable MAX_STALENESS;

    int256 public immutable MIN_ANSWER;

    int256 public immutable MAX_ANSWER;

    /* CONSTRUCTOR */

    /// @param fallbackMinAnswer 피드에서 하한을 읽지 못할 때 쓸 값
    /// @param fallbackMaxAnswer 피드에서 상한을 읽지 못할 때 쓸 값
    constructor(
        address feed,
        address loanToken,
        address collateralToken,
        uint256 maxStaleness,
        int256 fallbackMinAnswer,
        int256 fallbackMaxAnswer
    ) {
        require(feed != address(0) && loanToken != address(0) && collateralToken != address(0), ZeroAddress());
        require(maxStaleness != 0, ZeroStaleness());

        (int256 minAnswer, int256 maxAnswer) = _readBounds(feed, fallbackMinAnswer, fallbackMaxAnswer);
        require(minAnswer >= 0 && minAnswer < maxAnswer, InvalidBounds(minAnswer, maxAnswer));

        // 배율 = 10^(36 + 대출 자릿수 − 담보 자릿수 − 피드 자릿수)
        uint256 positive = PRICE_SCALE_DECIMALS + IERC20Metadata(loanToken).decimals();
        uint256 negative = uint256(IERC20Metadata(collateralToken).decimals()) + AggregatorV3Interface(feed).decimals();
        require(positive >= negative, UnsupportedDecimals());

        FEED = AggregatorV3Interface(feed);
        LOAN_TOKEN = loanToken;
        COLLATERAL_TOKEN = collateralToken;
        MAX_STALENESS = maxStaleness;
        MIN_ANSWER = minAnswer;
        MAX_ANSWER = maxAnswer;
        SCALE_FACTOR = 10 ** (positive - negative);
    }

    /* VIEW */

    function price() external view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = FEED.latestRoundData();

        require(answer > 0, NonPositivePrice(answer));
        require(answer > MIN_ANSWER && answer < MAX_ANSWER, PriceOutOfBounds(answer));
        require(
            updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_STALENESS,
            StalePrice(updatedAt)
        );

        return SafeCast.toUint256(answer) * SCALE_FACTOR;
    }

    /* INTERNAL */

    /// @dev 피드의 가격 하한과 상한 조회, 실패 시 넘겨받은 값 사용
    function _readBounds(address feed, int256 fallbackMinAnswer, int256 fallbackMaxAnswer)
        internal
        view
        returns (int256, int256)
    {
        try IAggregatorBounds(feed).aggregator() returns (address aggregator) {
            try IAggregatorBounds(aggregator).minAnswer() returns (int192 minAnswer) {
                try IAggregatorBounds(aggregator).maxAnswer() returns (int192 maxAnswer) {
                    if (minAnswer > 0 && maxAnswer > minAnswer) return (minAnswer, maxAnswer);
                } catch {}
            } catch {}
        } catch {}

        return (fallbackMinAnswer, fallbackMaxAnswer);
    }
}
