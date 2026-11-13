// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Market} from "../../src/Market.sol";
import {ILiquidateCallback} from "../../src/interfaces/ILiquidateCallback.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice 밑천 없이 콜백으로 청산하는 테스트용 청산자
contract CallbackLiquidator is ILiquidateCallback {
    Market internal immutable MARKET;
    MockERC20 internal immutable LOAN_TOKEN;
    IERC20 internal immutable COLLATERAL_TOKEN;

    bool public shouldReenter;
    // 콜백 안에서 본 값
    uint256 public collateralInCallback;
    uint256 public loanBalanceInCallback;
    uint256 public repaidAssetsInCallback;
    bytes public dataInCallback;
    bytes4 public reenterSelector;

    constructor(Market market) {
        MARKET = market;
        LOAN_TOKEN = MockERC20(market.asset());
        COLLATERAL_TOKEN = IERC20(market.COLLATERAL_TOKEN());
    }

    function setShouldReenter(bool value) external {
        shouldReenter = value;
    }

    function liquidate(address borrower, uint256 seizedAssets, bytes calldata data) external {
        MARKET.liquidate(borrower, seizedAssets, 0, data);
    }

    function onLiquidate(uint256 repaidAssets, uint256 seizedAssets, bytes calldata data) external {
        collateralInCallback = COLLATERAL_TOKEN.balanceOf(address(this));
        loanBalanceInCallback = LOAN_TOKEN.balanceOf(address(this));
        repaidAssetsInCallback = repaidAssets;
        dataInCallback = data;

        if (shouldReenter) {
            (, bytes memory reason) = address(MARKET)
                .call(abi.encodeCall(MARKET.withdrawCollateral, (seizedAssets, address(this), address(this))));
            reenterSelector = bytes4(reason);
        }

        // 갚을 만큼 대출 토큰 발행
        LOAN_TOKEN.mint(address(this), repaidAssets);
        LOAN_TOKEN.approve(address(MARKET), repaidAssets);
    }
}
