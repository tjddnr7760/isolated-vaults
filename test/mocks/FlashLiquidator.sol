// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Market} from "../../src/Market.sol";
import {IFlashLoanCallback} from "../../src/interfaces/IFlashLoanCallback.sol";
import {MockSwap} from "./MockSwap.sol";

/// @notice 다른 시장의 플래시론으로 청산하는 테스트용 청산자
contract FlashLiquidator is IFlashLoanCallback {
    Market internal immutable LENDER;
    Market internal immutable TARGET;
    MockSwap internal immutable SWAP;
    IERC20 internal immutable LOAN_TOKEN;
    IERC20 internal immutable COLLATERAL_TOKEN;

    constructor(Market lender, Market target, MockSwap swap) {
        LENDER = lender;
        TARGET = target;
        SWAP = swap;
        LOAN_TOKEN = IERC20(target.asset());
        COLLATERAL_TOKEN = IERC20(target.COLLATERAL_TOKEN());
    }

    function liquidate(address borrower, uint256 assets) external {
        LENDER.flashLoan(address(LOAN_TOKEN), assets, abi.encode(borrower));
    }

    function onFlashLoan(address, uint256 assets, bytes calldata data) external {
        address borrower = abi.decode(data, (address));

        // 빌린 돈으로 빚 전부 청산
        LOAN_TOKEN.approve(address(TARGET), assets);
        (uint256 seized,) = TARGET.liquidate(borrower, 0, type(uint256).max, "");

        // 받은 담보를 팔아 플래시론 상환
        COLLATERAL_TOKEN.approve(address(SWAP), seized);
        SWAP.swap(seized);
        LOAN_TOKEN.approve(address(LENDER), assets);
    }
}
