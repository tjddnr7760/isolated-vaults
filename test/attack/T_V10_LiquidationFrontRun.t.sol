// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Position} from "../../src/interfaces/IMarket.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 청산 직전 포지션을 조금 바꿔 전부 청산을 막는 공격
contract FrontRunFullCloseAttackTest is BaseTest {
    address internal ATTACKER = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        // 예치 10,000, 담보 5 WETH, 차입 7,000
        _setUpExample();
        loanToken.mint(LIQUIDATOR, 100_000e6);
        loanToken.mint(ATTACKER, 1e6);
        collateralToken.mint(ATTACKER, 1e18);
        vm.prank(LIQUIDATOR);
        loanToken.approve(address(market), type(uint256).max);
        vm.startPrank(ATTACKER);
        loanToken.approve(address(market), type(uint256).max);
        collateralToken.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev 청산 직전 담보 1 wei 추가
    function test_Attack_FrontRunSupplyOneWeiCollateral_Blocked() public {
        // given
        oracle.setPrice(PRICE_1000);

        vm.prank(ATTACKER);
        market.supplyCollateral(1, BORROWER);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized,) = market.liquidate(BORROWER, type(uint256).max, 0, "");

        // then
        assertEq(seized, 5e18 + 1);
        Position memory pos = market.position(BORROWER);
        assertEq(pos.collateral, 0);
        assertEq(pos.borrowShares, 0);
    }

    /// @dev 청산 직전 빚 지분 1 대신 상환
    function test_Attack_FrontRunRepayOneShare_Blocked() public {
        // given
        oracle.setPrice(PRICE_1600);
        uint256 borrowShares = market.position(BORROWER).borrowShares;

        vm.prank(ATTACKER);
        market.repay(0, 1, BORROWER);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 0, borrowShares, "");

        // then
        assertEq(market.position(BORROWER).borrowShares, 0);
        assertEq(market.debtOf(BORROWER), 0);
    }

    /// @dev 전액 상환 직전 빚 지분 1 대신 상환
    function test_Attack_FrontRunRepayBeforeFullRepay_Blocked() public {
        // given
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        loanToken.mint(BORROWER, 10_000e6);
        vm.prank(ATTACKER);
        market.repay(0, 1, BORROWER);

        // when
        vm.startPrank(BORROWER);
        loanToken.approve(address(market), type(uint256).max);
        (, uint256 repaidShares) = market.repay(0, borrowShares, BORROWER);
        vm.stopPrank();

        // then
        assertEq(repaidShares, borrowShares - 1);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }

    /// @dev 선행 상환을 당한 전액 상환 뒤 담보 전부 회수
    function test_Attack_FrontRunRepayBeforeCollateralWithdraw_Blocked() public {
        // given
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        loanToken.mint(BORROWER, 10_000e6);
        vm.prank(ATTACKER);
        market.repay(0, 1, BORROWER);
        vm.startPrank(BORROWER);
        loanToken.approve(address(market), type(uint256).max);
        market.repay(0, borrowShares, BORROWER);

        // when
        market.withdrawCollateral(5e18, BORROWER, BORROWER);
        vm.stopPrank();

        // then
        assertEq(collateralToken.balanceOf(BORROWER), 5e18);
    }
}
