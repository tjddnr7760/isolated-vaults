// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMarket, MarketState, Position} from "../../src/interfaces/IMarket.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 청산으로 작은 잔액을 남기는 공격
contract LiquidationDustAttackTest is BaseTest {
    function setUp() public override {
        super.setUp();
        // 예치 10,000, 담보 5 WETH, 차입 7,000
        _setUpExample();
        loanToken.mint(LIQUIDATOR, 100_000e6);
        loanToken.mint(BORROWER, 100_000e6);
        vm.prank(LIQUIDATOR);
        loanToken.approve(address(market), type(uint256).max);
        vm.prank(BORROWER);
        loanToken.approve(address(market), type(uint256).max);
    }

    /// @dev 자기 청산으로 빚 1 USDC 만 남기기
    function test_Attack_SelfLiquidationLeavesDustDebt_Blocked() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DebtBelowMinimum.selector, 1e6, MIN_DEBT));
        market.liquidate(BORROWER, 0, 6_999e6 * 1e6, "");
    }

    /// @dev 최소 부채까지 남기는 자기 청산은 허용
    function test_Attack_SelfLiquidationLeavesExactlyMinDebt() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when
        vm.prank(BORROWER);
        market.liquidate(BORROWER, 0, (7_000e6 - MIN_DEBT) * 1e6, "");

        // then
        assertEq(market.debtOf(BORROWER), MIN_DEBT);
    }

    /// @dev 담보 1 wei 를 남겨 부실 처리 미루기
    function test_Attack_LeaveOneWeiCollateral_Blocked() public {
        // given
        oracle.setPrice(PRICE_1000);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CollateralBelowMinimum.selector, 0, MIN_DEBT));
        market.liquidate(BORROWER, 5e18 - 1, 0, "");
    }

    /// @dev 담보를 전부 가져가는 청산의 부실 즉시 반영
    function test_Attack_SeizeAllCollateralRealizesBadDebt() public {
        // given
        oracle.setPrice(PRICE_1000);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 5e18, 0, "");

        // then
        Position memory pos = market.position(BORROWER);
        assertEq(pos.collateral, 0);
        assertEq(pos.borrowShares, 0);
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowAssets, 0);
        assertLt(state.totalSupplyAssets, 10_000e6);
    }

    /// @dev 최소 부채 이상 남기는 청산은 허용
    function test_Attack_LeftoverAboveMinimumIsProfitableToFinish() public {
        // given
        oracle.setPrice(PRICE_1000);
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 2.5e18, 0, "");

        // 다른 청산자가 남은 2.5 WETH 를 할인가로 청산
        loanToken.mint(OTHER, 100_000e6);

        // when
        vm.startPrank(OTHER);
        loanToken.approve(address(market), type(uint256).max);
        (uint256 seized, uint256 repaid) = market.liquidate(BORROWER, type(uint256).max, 0, "");
        vm.stopPrank();

        // then
        assertEq(seized, 2.5e18);
        assertLt(repaid, 2_500e6);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }
}
