// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market} from "../../src/Market.sol";
import {MarketParams, MarketState, Position} from "../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {FlashLiquidator} from "../mocks/FlashLiquidator.sol";
import {MockSwap} from "../mocks/MockSwap.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 가격 하락에서 청산과 손실 처리로 이어지는 흐름
contract LiquidationScenarioTest is BaseTest {
    /// @dev 대출 → 가격 하락 → 청산
    function test_Scenario_Liquidation_LiquidatorEarnsAndSupplierKeepsPrincipal() public {
        // given
        uint256 shares = _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 7_000e6);
        oracle.setPrice(PRICE_1600);
        loanToken.mint(LIQUIDATOR, 7_000e6);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = market.liquidate(BORROWER, 0, type(uint256).max, "");

        // then
        uint256 seizedValue = Math.mulDiv(seized, PRICE_1600, ConstantsLib.ORACLE_PRICE_SCALE);
        assertEq(repaid, 7_000e6);
        assertGt(seizedValue, repaid);
        assertEq(collateralToken.balanceOf(LIQUIDATOR), seized);
        // 차입자는 빚이 없고 남은 담보 보유
        Position memory pos = market.position(BORROWER);
        assertEq(pos.borrowShares, 0);
        assertEq(pos.collateral, 5e18 - seized);
        // 예치자 원금 유지
        assertEq(market.previewRedeem(shares), 10_000e6);
    }

    /// @dev 대출 → 가격 급락 → 담보 전부 청산
    function test_Scenario_BadDebt_ReserveAbsorbsFirstThenSuppliersShare() public {
        // given
        uint256 sharesA = _deposit(SUPPLIER, 7_500e6);
        uint256 sharesB = _deposit(OTHER, 2_500e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 7_000e6);
        _forward(365 days);
        market.accrueInterest();
        MarketState memory beforeState = market.marketState();
        assertGt(beforeState.reserve, 0);
        oracle.setPrice(PRICE_1000);
        loanToken.mint(LIQUIDATOR, 7_000e6);

        // when
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = market.liquidate(BORROWER, 5e18, 0, "");

        // then
        MarketState memory afterState = market.marketState();
        uint256 badDebt = beforeState.totalBorrowAssets - repaid;
        assertEq(afterState.totalBorrowAssets, 0);
        assertEq(afterState.reserve, 0);
        assertEq(beforeState.totalSupplyAssets - afterState.totalSupplyAssets, badDebt - beforeState.reserve);
        // 예치자 손실은 지분 비율대로 3 대 1
        assertApproxEqAbs(market.previewRedeem(sharesA), 3 * market.previewRedeem(sharesB), 3);
    }

    /// @dev 플래시론 → 청산 → 받은 담보로 상환
    function test_Scenario_FlashLoanLiquidation_NeedsNoOwnFunds() public {
        // given
        _setUpExample();
        MarketParams memory lenderParams = params;
        lenderParams.lltv = 0.8e18;
        Market lender = _deployMarket(lenderParams);
        loanToken.mint(OTHER, 20_000e6);
        vm.prank(OTHER);
        lender.deposit(20_000e6, OTHER);
        MarketState memory lenderBefore = lender.marketState();
        MockSwap swap = new MockSwap(loanToken, collateralToken, oracle);
        FlashLiquidator liquidator = new FlashLiquidator(lender, market, swap);
        oracle.setPrice(PRICE_1600);
        assertEq(loanToken.balanceOf(address(liquidator)), 0);

        // when
        liquidator.liquidate(BORROWER, 7_000e6);

        // then
        assertEq(market.position(BORROWER).borrowShares, 0);
        assertGt(loanToken.balanceOf(address(liquidator)), 0);
        assertEq(collateralToken.balanceOf(address(liquidator)), 0);
        // 돈을 빌려준 시장의 잔액과 장부 유지
        assertEq(loanToken.balanceOf(address(lender)), 20_000e6);
        assertEq(abi.encode(lender.marketState()), abi.encode(lenderBefore));
    }
}
