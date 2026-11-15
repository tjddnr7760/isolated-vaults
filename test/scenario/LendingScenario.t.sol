// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {MarketState} from "../../src/interfaces/IMarket.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 예치, 대출, 상환, 인출로 이어지는 사용 흐름
contract LendingScenarioTest is BaseTest {
    /// @dev 예치 → 대출 → 1년 경과 → 전액 상환 → 전액 인출
    function test_Scenario_BorrowAndRepay_InterestGoesToSupplierAndReserve() public {
        // given
        uint256 shares = _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 7_000e6);
        _forward(365 days);
        loanToken.mint(BORROWER, 1_000e6);

        // when
        vm.startPrank(BORROWER);
        (uint256 repaid,) = market.repay(0, type(uint256).max, BORROWER);
        market.withdrawCollateral(5e18, BORROWER, BORROWER);
        vm.stopPrank();
        vm.prank(SUPPLIER);
        uint256 redeemed = market.redeem(shares, SUPPLIER, SUPPLIER);

        // then
        uint256 interestPaid = repaid - 7_000e6;
        uint256 interestReceived = redeemed - 10_000e6;
        uint256 reserve = market.marketState().reserve;
        assertGt(interestReceived, 0);
        assertGt(reserve, 0);
        // 반올림으로 시장에 남는 몫 1 단위 이내
        assertApproxEqAbs(interestPaid, interestReceived + reserve, 1);
        assertEq(loanToken.balanceOf(address(market)), interestPaid - interestReceived);
        assertEq(collateralToken.balanceOf(BORROWER), 5e18);
    }

    /// @dev A 예치 → 시간 경과 → B 예치 → 시간 경과 → 함께 인출
    function test_Scenario_TwoSuppliers_LateSupplierEarnsOnlyItsPeriod() public {
        // given
        uint256 sharesA = _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 7_000e6);
        _forward(180 days);
        market.accrueInterest();
        uint256 valueABeforeB = market.previewRedeem(sharesA);
        uint256 sharesB = _deposit(OTHER, 10_000e6);
        uint256 valueAAfterB = market.previewRedeem(sharesA);
        _forward(180 days);
        loanToken.mint(BORROWER, 1_000e6);
        vm.prank(BORROWER);
        market.repay(0, type(uint256).max, BORROWER);

        // when
        vm.prank(SUPPLIER);
        uint256 redeemedA = market.redeem(sharesA, SUPPLIER, SUPPLIER);
        vm.prank(OTHER);
        uint256 redeemedB = market.redeem(sharesB, OTHER, OTHER);

        // then
        // B 의 예치가 A 의 몫을 바꾸지 않음
        assertEq(valueAAfterB, valueABeforeB);
        // 두 번째 기간의 이자는 예치 금액에 비례
        uint256 secondPeriodA = redeemedA - valueABeforeB;
        uint256 interestB = redeemedB - 10_000e6;
        assertApproxEqAbs(interestB, secondPeriodA * 10_000e6 / valueABeforeB, 1);
        assertGt(redeemedA - 10_000e6, interestB);
    }

    /// @dev 대부분 대출 → 인출 실패 → 상환 → 인출 성공
    function test_Scenario_LiquidityShortage_WithdrawWorksAfterRepay() public {
        // given
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 10e18);
        _borrow(BORROWER, 9_900e6);
        MarketState memory state = market.marketState();
        // 이용률 99% 의 금리는 최적 이용률의 금리보다 높음
        assertGt(irm.borrowRate(state.totalSupplyAssets, state.totalBorrowAssets), BASE_RATE + SLOPE_1);
        vm.prank(SUPPLIER);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, SUPPLIER, 1_000e6, 100e6));
        market.withdraw(1_000e6, SUPPLIER, SUPPLIER);

        // when
        vm.prank(BORROWER);
        market.repay(5_000e6, 0, BORROWER);
        vm.prank(SUPPLIER);
        market.withdraw(1_000e6, SUPPLIER, SUPPLIER);

        // then
        assertEq(loanToken.balanceOf(SUPPLIER), 1_000e6);
        assertEq(market.liquidity(), 4_100e6);
    }
}
