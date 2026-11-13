// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IRateModel} from "../../src/interfaces/IRateModel.sol";

/// @notice 금리를 직접 넣는 테스트용 금리 모델
contract MockRateModel is IRateModel {
    error RateModelDown();

    uint256 internal _rate;
    bool internal _isDown;

    function setRate(uint256 newRate) external {
        _rate = newRate;
    }

    function setDown(bool isDown) external {
        _isDown = isDown;
    }

    function borrowRate(uint256, uint256) external view returns (uint256) {
        require(!_isDown, RateModelDown());
        return _rate;
    }
}
