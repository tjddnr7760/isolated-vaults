// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @notice 가격을 직접 넣는 테스트용 오라클
contract MockOracleAdapter is IOracle {
    error OracleDown();

    address public immutable LOAN_TOKEN;
    address public immutable COLLATERAL_TOKEN;

    uint256 internal _price;
    bool internal _isDown;

    constructor(address loanToken, address collateralToken) {
        LOAN_TOKEN = loanToken;
        COLLATERAL_TOKEN = collateralToken;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setDown(bool isDown) external {
        _isDown = isDown;
    }

    function price() external view returns (uint256) {
        require(!_isDown, OracleDown());
        return _price;
    }
}
