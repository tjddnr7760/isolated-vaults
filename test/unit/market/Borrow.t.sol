// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMarket, MarketState} from "../../../src/interfaces/IMarket.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MockOracleAdapter} from "../../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../../BaseTest.sol";

contract BorrowTest is BaseTest {
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    function setUp() public override {
        super.setUp();
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
    }

    function test_Borrow_RecordsSharesAndSendsAssets() public {
        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.Borrow(BORROWER, BORROWER, RECEIVER, 7_000e6, 7_000e6 * VIRTUAL_SHARES);
        vm.prank(BORROWER);
        uint256 shares = market.borrow(7_000e6, BORROWER, RECEIVER);

        // then
        // 빈 장부에서 7,000e6 × (0 + 1e6) ÷ (0 + 1)
        assertEq(shares, 7_000e6 * VIRTUAL_SHARES);
        assertEq(market.position(BORROWER).borrowShares, shares);
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowAssets, 7_000e6);
        assertEq(state.totalBorrowShares, shares);
        assertEq(loanToken.balanceOf(RECEIVER), 7_000e6);
        assertEq(market.debtOf(BORROWER), 7_000e6);
        assertEq(market.liquidity(), 3_000e6);
    }

    function test_Borrow_RevertWhen_ZeroAssets() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAssets.selector);
        market.borrow(0, BORROWER, BORROWER);
    }

    function test_Borrow_RevertWhen_ReceiverZero() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.borrow(1_000e6, BORROWER, address(0));
    }

    function test_Borrow_RevertWhen_NotOwner() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.borrow(1_000e6, BORROWER, OTHER);
    }

    /// @dev 한도 8,600 에서 1 더 빌리면 거절
    function test_Borrow_RevertWhen_AboveHealthLimit() public {
        // given
        uint256 limit = _maxBorrow(5e18, PRICE_2000);
        assertEq(limit, 8_600e6);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.Unhealthy.selector);
        market.borrow(limit + 1, BORROWER, BORROWER);
    }

    /// @dev 한도 8,600 까지는 대출 가능
    function test_Borrow_UpToHealthLimit() public {
        // given
        uint256 limit = _maxBorrow(5e18, PRICE_2000);
        assertEq(limit, 8_600e6);

        // when
        _borrow(BORROWER, limit);

        // then
        assertTrue(market.isHealthy(BORROWER));
    }

    function test_Borrow_RevertWhen_BelowMinDebt() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DebtBelowMinimum.selector, MIN_DEBT - 1, MIN_DEBT));
        market.borrow(MIN_DEBT - 1, BORROWER, BORROWER);
    }

    function test_Borrow_ExactlyMinDebt() public {
        // when
        _borrow(BORROWER, MIN_DEBT);

        // then
        assertEq(market.debtOf(BORROWER), MIN_DEBT);
    }

    function test_Borrow_RevertWhen_InsufficientLiquidity() public {
        // given
        _supplyCollateral(OTHER, 100e18);

        // when, then
        vm.prank(OTHER);
        vm.expectRevert(IMarket.InsufficientLiquidity.selector);
        market.borrow(10_000e6 + 1, OTHER, OTHER);
    }

    function test_Borrow_AllLiquidity() public {
        // given
        _supplyCollateral(OTHER, 100e18);

        // when
        _borrow(OTHER, 10_000e6);

        // then
        assertEq(market.liquidity(), 0);
    }

    function test_Borrow_RevertWhen_OracleIsDown() public {
        // given
        oracle.setDown(true);

        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(MockOracleAdapter.OracleDown.selector);
        market.borrow(1_000e6, BORROWER, BORROWER);
    }

    function test_Borrow_RevertWhen_NoCollateral() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert(IMarket.Unhealthy.selector);
        market.borrow(MIN_DEBT, OTHER, OTHER);
    }

    function test_Borrow_AccruesInterestFirst() public {
        // given
        _borrow(BORROWER, 7_000e6);
        _forward(30 days);
        uint256 expectedBorrow = market.expectedMarketState().totalBorrowAssets;

        // when
        _borrow(BORROWER, 100e6);

        // then
        assertEq(market.marketState().totalBorrowAssets, expectedBorrow + 100e6);
        assertEq(market.marketState().lastUpdate, block.timestamp);
    }

    /// @dev 받은 자산 ≤ 생긴 빚
    function testFuzz_Borrow_DebtIncreaseCoversAssets(uint256 first, uint256 second, uint256 elapsed) public {
        // given
        first = bound(first, MIN_DEBT, 4_000e6);
        second = bound(second, 1, 4_000e6);
        elapsed = bound(elapsed, 1, 365 days);
        _borrow(BORROWER, first);
        _forward(elapsed);
        uint256 debtBefore = market.debtOf(BORROWER);

        // when
        _borrow(BORROWER, second);

        // then
        assertGe(market.debtOf(BORROWER) - debtBefore, second);
        // 올림 손해는 2 wei 이하
        assertLe(market.debtOf(BORROWER) - debtBefore, second + 2);
    }

    function testFuzz_Borrow_SuccessImpliesHealthyAndAboveMinDebt(uint256 assets, uint256 price) public {
        // given
        assets = bound(assets, 1, 10_000e6);
        price = bound(price, PRICE_1000 / 10, PRICE_2000 * 10);
        oracle.setPrice(price);

        // when, then
        vm.prank(BORROWER);
        try market.borrow(assets, BORROWER, BORROWER) {
            assertTrue(market.isHealthy(BORROWER));
            assertGe(market.debtOf(BORROWER), MIN_DEBT);
            assertLe(market.debtOf(BORROWER), _maxBorrow(5e18, price));
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(selector == IMarket.Unhealthy.selector || selector == IMarket.DebtBelowMinimum.selector);
        }
    }
}
