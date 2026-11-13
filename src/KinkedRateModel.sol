// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "morpho-blue/libraries/MathLib.sol";

import {IRateModel} from "./interfaces/IRateModel.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";

/// @notice 이용률 기준 두 구간 직선 금리 모델
contract KinkedRateModel is IRateModel {
    /* ERRORS */

    error InvalidOptimalUtilization(uint256 optimalUtilization);

    error RateTooHigh(uint256 maxRate);

    /* IMMUTABLES */

    /// @notice 최적 이용률 (WAD)
    uint256 public immutable OPTIMAL_UTILIZATION;

    /// @notice 기본 금리 (초당, WAD)
    uint256 public immutable BASE_RATE;

    /// @notice 최적 이용률까지의 금리 증가분 (초당, WAD)
    uint256 public immutable SLOPE_1;

    /// @notice 최적 이용률 이후의 금리 증가분 (초당, WAD)
    uint256 public immutable SLOPE_2;

    /* CONSTRUCTOR */

    constructor(uint256 optimalUtilization, uint256 baseRate, uint256 slope1, uint256 slope2) {
        // 0 나눗셈 방지
        require(optimalUtilization != 0 && optimalUtilization < WAD, InvalidOptimalUtilization(optimalUtilization));
        // 덧셈 넘침 방지
        require(
            baseRate <= ConstantsLib.MAX_BORROW_RATE && slope1 <= ConstantsLib.MAX_BORROW_RATE
                && slope2 <= ConstantsLib.MAX_BORROW_RATE,
            RateTooHigh(type(uint256).max)
        );
        uint256 maxRate = baseRate + slope1 + slope2;
        require(maxRate <= ConstantsLib.MAX_BORROW_RATE, RateTooHigh(maxRate));

        OPTIMAL_UTILIZATION = optimalUtilization;
        BASE_RATE = baseRate;
        SLOPE_1 = slope1;
        SLOPE_2 = slope2;
    }

    /* VIEW */

    function borrowRate(uint256 totalSupplyAssets, uint256 totalBorrowAssets) external view returns (uint256) {
        uint256 utilization = _utilization(totalSupplyAssets, totalBorrowAssets);

        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_RATE + Math.mulDiv(SLOPE_1, utilization, OPTIMAL_UTILIZATION);
        }

        return BASE_RATE + SLOPE_1 + Math.mulDiv(SLOPE_2, utilization - OPTIMAL_UTILIZATION, WAD - OPTIMAL_UTILIZATION);
    }

    /* INTERNAL */

    /// @dev 이용률 (WAD, 내림)
    function _utilization(uint256 totalSupplyAssets, uint256 totalBorrowAssets) internal pure returns (uint256) {
        if (totalBorrowAssets == 0) return 0;
        if (totalBorrowAssets >= totalSupplyAssets) return WAD;

        return Math.mulDiv(totalBorrowAssets, WAD, totalSupplyAssets);
    }
}
