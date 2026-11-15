// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../../src/interfaces/IOracle.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice 오라클 가격으로 담보를 대출 토큰으로 바꿔 주는 테스트용 교환소
contract MockSwap {
    MockERC20 internal immutable LOAN_TOKEN;
    IERC20 internal immutable COLLATERAL_TOKEN;
    IOracle internal immutable ORACLE;

    constructor(MockERC20 loanToken, IERC20 collateralToken, IOracle oracle) {
        LOAN_TOKEN = loanToken;
        COLLATERAL_TOKEN = collateralToken;
        ORACLE = oracle;
    }

    function swap(uint256 collateralAssets) external returns (uint256 loanAssets) {
        loanAssets = Math.mulDiv(collateralAssets, ORACLE.price(), ConstantsLib.ORACLE_PRICE_SCALE);

        COLLATERAL_TOKEN.transferFrom(msg.sender, address(this), collateralAssets);
        LOAN_TOKEN.mint(msg.sender, loanAssets);
    }
}
