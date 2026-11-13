// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMarket, MarketState} from "../../../src/interfaces/IMarket.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {BaseTest} from "../../BaseTest.sol";

contract RepayTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _setUpExample();
    }

    function test_Repay_ByAssetsReducesDebt() public {
        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.Repay(BORROWER, BORROWER, 3_000e6, 3_000e6 * 1e6);
        vm.prank(BORROWER);
        (uint256 assets, uint256 shares) = market.repay(3_000e6, 0, BORROWER);

        // then
        assertEq(assets, 3_000e6);
        assertEq(shares, 3_000e6 * 1e6);
        assertEq(market.debtOf(BORROWER), 4_000e6);
        assertEq(market.marketState().totalBorrowAssets, 4_000e6);
        assertEq(loanToken.balanceOf(BORROWER), 4_000e6);
    }

    function test_Repay_ByOtherOnBehalfOfBorrower() public {
        // given
        loanToken.mint(OTHER, 1_000e6);

        // when
        vm.prank(OTHER);
        market.repay(1_000e6, 0, BORROWER);

        // then
        assertEq(market.debtOf(BORROWER), 6_000e6);
        assertEq(loanToken.balanceOf(OTHER), 0);
    }

    /// @dev 이자가 붙은 뒤 지분 전부로 갚으면 빚과 총 차입이 0
    function test_Repay_AllSharesClearsDebtAfterInterest() public {
        // given
        _forward(90 days);
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        uint256 debt = market.debtOf(BORROWER);
        loanToken.mint(BORROWER, 1_000e6);
        uint256 balanceBefore = loanToken.balanceOf(BORROWER);

        // when
        vm.prank(BORROWER);
        (uint256 assets, uint256 shares) = market.repay(0, borrowShares, BORROWER);

        // then
        assertEq(shares, borrowShares);
        assertEq(assets, debt);
        assertEq(balanceBefore - loanToken.balanceOf(BORROWER), debt);
        assertEq(market.position(BORROWER).borrowShares, 0);
        assertEq(market.debtOf(BORROWER), 0);
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowShares, 0);
        assertEq(state.totalBorrowAssets, 0);
    }

    function test_Repay_RevertWhen_BothInputsZero() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.InconsistentInput.selector);
        market.repay(0, 0, BORROWER);
    }

    function test_Repay_RevertWhen_BothInputsNonZero() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.InconsistentInput.selector);
        market.repay(1e6, 1e12, BORROWER);
    }

    function test_Repay_RevertWhen_OnBehalfZero() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.repay(1e6, 0, address(0));
    }

    /// @dev 큰 값 입력 시 지분 전부 상환
    function test_Repay_SharesAboveDebtMeansAll() public {
        // given
        _forward(30 days);
        // 이자만큼 추가 지급
        loanToken.mint(BORROWER, 2_000e6);
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        uint256 debt = market.debtOf(BORROWER);
        uint256 balanceBefore = loanToken.balanceOf(BORROWER);

        // when
        vm.prank(BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) = market.repay(0, type(uint256).max, BORROWER);

        // then
        assertEq(repaidShares, borrowShares);
        assertEq(repaidAssets, debt);
        assertEq(balanceBefore - loanToken.balanceOf(BORROWER), debt);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }

    /// @dev 빚보다 많은 금액 입력 시 빚만큼만 상환
    function test_Repay_AssetsAboveDebtMeansAll() public {
        // given
        _forward(30 days);
        // 이자만큼 추가 지급
        loanToken.mint(BORROWER, 2_000e6);
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        uint256 debt = market.debtOf(BORROWER);
        uint256 balanceBefore = loanToken.balanceOf(BORROWER);

        // when
        vm.prank(BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) = market.repay(debt + 1_000e6, 0, BORROWER);

        // then
        assertEq(repaidShares, borrowShares);
        assertEq(repaidAssets, debt);
        assertEq(balanceBefore - loanToken.balanceOf(BORROWER), debt);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }

    /// @dev 빚보다 적은 금액은 그대로 상환
    function test_Repay_AssetsBelowDebtTakesExactAssets() public {
        // given
        _forward(30 days);

        // when
        vm.prank(BORROWER);
        (uint256 repaidAssets,) = market.repay(1_000e6, 0, BORROWER);

        // then
        assertEq(repaidAssets, 1_000e6);
    }

    function test_Repay_RevertWhen_LeavesDebtBelowMinimum() public {
        // given
        uint256 leaveBelow = 7_000e6 - MIN_DEBT + 1;

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DebtBelowMinimum.selector, MIN_DEBT - 1, MIN_DEBT));
        market.repay(leaveBelow, 0, BORROWER);
    }

    function test_Repay_LeavesDebtExactlyMinimum() public {
        // when
        vm.prank(BORROWER);
        market.repay(7_000e6 - MIN_DEBT, 0, BORROWER);

        // then
        assertEq(market.debtOf(BORROWER), MIN_DEBT);
    }

    function test_Repay_WorksWhenOracleIsDown() public {
        // given
        oracle.setDown(true);

        // when
        vm.prank(BORROWER);
        market.repay(1_000e6, 0, BORROWER);

        // then
        assertEq(market.debtOf(BORROWER), 6_000e6);
    }

    /// @dev 낸 자산 ≥ 줄어든 빚
    function testFuzz_Repay_AssetsPaidCoverDebtDecrease(uint256 repaid, uint256 elapsed) public {
        // given
        elapsed = bound(elapsed, 1, 365 days);
        _forward(elapsed);
        uint256 debtBefore = market.debtOf(BORROWER);
        repaid = bound(repaid, 1, debtBefore - MIN_DEBT);
        loanToken.mint(BORROWER, 2_000e6);

        // when
        vm.prank(BORROWER);
        (uint256 assets,) = market.repay(repaid, 0, BORROWER);

        // then
        assertEq(assets, repaid);
        assertGe(repaid, debtBefore - market.debtOf(BORROWER));
    }

    /// @dev 상환 뒤 빚은 0 이거나 최소 부채 이상
    function testFuzz_Repay_SuccessImpliesZeroOrAboveMinDebt(uint256 repaidShares, uint256 elapsed) public {
        // given
        elapsed = bound(elapsed, 0, 365 days);
        _forward(elapsed);
        repaidShares = bound(repaidShares, 1, market.position(BORROWER).borrowShares);
        loanToken.mint(BORROWER, 2_000e6);

        // when, then
        vm.prank(BORROWER);
        try market.repay(0, repaidShares, BORROWER) {
            uint256 debt = market.debtOf(BORROWER);
            assertTrue(debt == 0 || debt >= MIN_DEBT);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IMarket.DebtBelowMinimum.selector);
        }
    }
}
