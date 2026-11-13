// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMarket} from "../../../src/interfaces/IMarket.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MockOracleAdapter} from "../../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../../BaseTest.sol";

contract CollateralTest is BaseTest {
    /* supplyCollateral */

    function test_SupplyCollateral_UpdatesPositionAndPullsTokens() public {
        // given
        collateralToken.mint(BORROWER, 5e18);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.SupplyCollateral(BORROWER, BORROWER, 5e18);
        vm.prank(BORROWER);
        market.supplyCollateral(5e18, BORROWER);

        // then
        assertEq(market.position(BORROWER).collateral, 5e18);
        assertEq(collateralToken.balanceOf(address(market)), 5e18);
        assertEq(collateralToken.balanceOf(BORROWER), 0);
    }

    function test_SupplyCollateral_OnBehalfOfOther() public {
        // given
        collateralToken.mint(OTHER, 1e18);

        // when
        vm.prank(OTHER);
        market.supplyCollateral(1e18, BORROWER);

        // then
        assertEq(market.position(BORROWER).collateral, 1e18);
        assertEq(market.position(OTHER).collateral, 0);
    }

    function test_SupplyCollateral_RevertWhen_ZeroAssets() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAssets.selector);
        market.supplyCollateral(0, BORROWER);
    }

    function test_SupplyCollateral_RevertWhen_OnBehalfZero() public {
        // given
        collateralToken.mint(BORROWER, 1e18);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.supplyCollateral(1e18, address(0));
    }

    /* withdrawCollateral */

    function test_WithdrawCollateral_SendsToReceiver() public {
        // given
        _supplyCollateral(BORROWER, 5e18);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.WithdrawCollateral(BORROWER, BORROWER, RECEIVER, 2e18);
        vm.prank(BORROWER);
        market.withdrawCollateral(2e18, BORROWER, RECEIVER);

        // then
        assertEq(market.position(BORROWER).collateral, 3e18);
        assertEq(collateralToken.balanceOf(RECEIVER), 2e18);
    }

    function test_WithdrawCollateral_WorksWithoutDebtWhenOracleIsDown() public {
        // given
        _supplyCollateral(BORROWER, 5e18);
        oracle.setDown(true);

        // when
        vm.prank(BORROWER);
        market.withdrawCollateral(5e18, BORROWER, BORROWER);

        // then
        assertEq(market.position(BORROWER).collateral, 0);
    }

    function test_WithdrawCollateral_RevertWhen_OracleIsDownWithDebt() public {
        // given
        _setUpExample();
        oracle.setDown(true);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(MockOracleAdapter.OracleDown.selector);
        market.withdrawCollateral(1, BORROWER, BORROWER);
    }

    function test_WithdrawCollateral_RevertWhen_NotOwner() public {
        // given
        _supplyCollateral(BORROWER, 5e18);

        // when, then
        vm.prank(OTHER);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.withdrawCollateral(1e18, BORROWER, OTHER);
    }

    function test_WithdrawCollateral_RevertWhen_ZeroAssets() public {
        // given
        _supplyCollateral(BORROWER, 5e18);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAssets.selector);
        market.withdrawCollateral(0, BORROWER, BORROWER);
    }

    function test_WithdrawCollateral_RevertWhen_ReceiverZero() public {
        // given
        _supplyCollateral(BORROWER, 5e18);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.withdrawCollateral(1e18, BORROWER, address(0));
    }

    function test_WithdrawCollateral_RevertWhen_MoreThanSupplied() public {
        // given
        _supplyCollateral(BORROWER, 5e18);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert();
        market.withdrawCollateral(5e18 + 1, BORROWER, BORROWER);
    }

    /// @dev 빚 7,000 을 감당하는 최소 담보
    function _minCollateralForExampleDebt() internal view returns (uint256 minCollateral) {
        uint256 debt = market.debtOf(BORROWER);
        // 담보 가치가 대출 자산 1 단위만큼 바뀌는 담보량
        uint256 step = 1e36 / PRICE_2000;
        minCollateral = debt * 1e18 / LLTV * step;
        while (_maxBorrow(minCollateral, PRICE_2000) < debt) minCollateral += step;
    }

    /// @dev 건강 경계에서 1 wei 더 꺼내면 거절
    function test_WithdrawCollateral_RevertWhen_BelowHealthBoundary() public {
        // given
        _setUpExample();
        uint256 minCollateral = _minCollateralForExampleDebt();

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.Unhealthy.selector);
        market.withdrawCollateral(5e18 - minCollateral + 1, BORROWER, BORROWER);
    }

    /// @dev 건강 경계까지는 인출 가능
    function test_WithdrawCollateral_DownToHealthBoundary() public {
        // given
        _setUpExample();
        uint256 minCollateral = _minCollateralForExampleDebt();

        // when
        vm.prank(BORROWER);
        market.withdrawCollateral(5e18 - minCollateral, BORROWER, BORROWER);

        // then
        assertTrue(market.isHealthy(BORROWER));
    }

    function testFuzz_WithdrawCollateral_SuccessImpliesHealthy(uint256 borrowed, uint256 withdrawn) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        withdrawn = bound(withdrawn, 1, 5e18);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);

        // when, then
        vm.prank(BORROWER);
        try market.withdrawCollateral(withdrawn, BORROWER, BORROWER) {
            assertTrue(market.isHealthy(BORROWER));
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IMarket.Unhealthy.selector);
        }
    }

    /// @dev 이벤트의 onBehalf 는 호출자가 아닌 포지션 주인
    function test_SupplyCollateral_EmitsOnBehalfNotCaller() public {
        // given
        uint256 collateralBefore = market.position(BORROWER).collateral;
        collateralToken.mint(OTHER, 1e18);
        vm.startPrank(OTHER);
        collateralToken.approve(address(market), 1e18);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.SupplyCollateral(OTHER, BORROWER, 1e18);
        market.supplyCollateral(1e18, BORROWER);
        vm.stopPrank();

        // then
        assertEq(market.position(BORROWER).collateral, collateralBefore + 1e18);
        assertEq(market.position(OTHER).collateral, 0);
    }
}
