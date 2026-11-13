// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MathLib} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "../../../src/Market.sol";
import {MarketParams, MarketState} from "../../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MockRateModel} from "../../mocks/MockRateModel.sol";
import {BaseTest} from "../../BaseTest.sol";

contract AccrueInterestTest is BaseTest {
    using MathLib for uint256;

    /// @dev 금리를 직접 넣는 금리 모델로 시장 배포
    function _deployWithMockRate() internal returns (Market mockMarket, MockRateModel mockIrm) {
        mockIrm = new MockRateModel();
        MarketParams memory p = params;
        p.irm = address(mockIrm);
        mockMarket = _deployMarket(p);

        loanToken.mint(SUPPLIER, 10_000e6);
        collateralToken.mint(BORROWER, 5e18);
        vm.prank(SUPPLIER);
        mockMarket.deposit(10_000e6, SUPPLIER);
        vm.startPrank(BORROWER);
        mockMarket.supplyCollateral(5e18, BORROWER);
        mockMarket.borrow(7_000e6, BORROWER, BORROWER);
        vm.stopPrank();
    }

    function test_AccrueInterest_SplitsInterestBetweenSuppliersAndReserve() public {
        // given
        _setUpExample();
        uint256 rate = irm.borrowRate(10_000e6, 7_000e6);
        _forward(30 days);
        // 30일 이자 계산
        uint256 interest = uint256(7_000e6).wMulDown(rate.wTaylorCompounded(30 days));
        uint256 reserveAssets = interest.mulDivUp(RESERVE_FACTOR, 1e18);
        assertGt(interest, 0);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.AccrueInterest(rate, interest, reserveAssets);
        market.accrueInterest();

        // then
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowAssets, 7_000e6 + interest);
        assertEq(state.totalSupplyAssets, 10_000e6 + interest - reserveAssets);
        assertEq(state.reserve, reserveAssets);
        assertEq(state.lastUpdate, block.timestamp);
        // 지분 수는 그대로, 빚만 증가
        assertEq(state.totalBorrowShares, 7_000e6 * 1e6);
        assertEq(market.debtOf(BORROWER), 7_000e6 + interest);
    }

    /// @dev 준비금 몫이 1 미만이어도 올림으로 1
    function test_AccrueInterest_ReserveShareRoundsUp() public {
        // given
        _setUpExample();
        uint256 rate = irm.borrowRate(10_000e6, 7_000e6);
        _forward(1);
        uint256 interest = uint256(7_000e6).wMulDown(rate.wTaylorCompounded(1));
        // 1 초 이자의 10% 는 1 미만
        assertGt(interest, 1);
        assertEq(interest.wMulDown(RESERVE_FACTOR), 0);

        // when
        market.accrueInterest();

        // then
        MarketState memory state = market.marketState();
        assertEq(state.reserve, 1);
        assertEq(state.totalSupplyAssets, 10_000e6 + interest - 1);
        assertEq(state.totalBorrowAssets, 7_000e6 + interest);
    }

    /// @dev 준비금 몫은 이자 이하
    function testFuzz_AccrueInterest_ReserveShareNeverExceedsInterest(uint256 elapsed) public {
        // given
        _setUpExample();
        elapsed = bound(elapsed, 1, 365 days);
        MarketState memory beforeState = market.marketState();
        _forward(elapsed);

        // when
        market.accrueInterest();

        // then
        MarketState memory state = market.marketState();
        uint256 interest = state.totalBorrowAssets - beforeState.totalBorrowAssets;
        uint256 reserveAssets = state.reserve - beforeState.reserve;
        assertLe(reserveAssets, interest);
        assertEq(reserveAssets, interest.mulDivUp(RESERVE_FACTOR, 1e18));
        assertEq(state.totalSupplyAssets - beforeState.totalSupplyAssets, interest - reserveAssets);
    }

    /// @dev 총 차입 7,000, 연 10%, 30일이면 이자 57.77
    function test_AccrueInterest_MatchesDesignExample() public {
        // given
        (Market mockMarket, MockRateModel mockIrm) = _deployWithMockRate();
        mockIrm.setRate(uint256(0.1e18) / 365 days);
        _forward(30 days);

        // when
        mockMarket.accrueInterest();

        // then
        MarketState memory state = mockMarket.marketState();
        uint256 interest = state.totalBorrowAssets - 7_000e6;
        assertApproxEqAbs(interest, 57.77e6, 0.01e6);
        assertApproxEqAbs(state.reserve, 5.78e6, 0.01e6);
        assertEq(state.totalSupplyAssets, 10_000e6 + interest - state.reserve);
    }

    /// @dev 같은 블록의 두 번째 반영은 변화 없음
    function test_AccrueInterest_IdempotentInSameBlock() public {
        // given
        _setUpExample();
        _forward(30 days);
        market.accrueInterest();
        MarketState memory first = market.marketState();

        // when
        market.accrueInterest();

        // then
        MarketState memory second = market.marketState();
        assertEq(abi.encode(first), abi.encode(second));
    }

    /// @dev 빚이 없으면 금리 모델 호출 없이 시각만 이동
    function test_AccrueInterest_OnlyMovesTimeWhenNoBorrow() public {
        // given
        MockRateModel mockIrm = new MockRateModel();
        MarketParams memory p = params;
        p.irm = address(mockIrm);
        Market mockMarket = _deployMarket(p);
        loanToken.mint(SUPPLIER, 1_000e6);
        vm.prank(SUPPLIER);
        mockMarket.deposit(1_000e6, SUPPLIER);
        mockIrm.setDown(true);
        _forward(30 days);

        // when
        mockMarket.accrueInterest();

        // then
        MarketState memory state = mockMarket.marketState();
        assertEq(state.lastUpdate, block.timestamp);
        assertEq(state.totalSupplyAssets, 1_000e6);
        assertEq(state.reserve, 0);
    }

    /// @dev 터무니없는 금리는 상한으로 제한
    function test_AccrueInterest_CapsRateAtMaxBorrowRate() public {
        // given
        (Market mockMarket, MockRateModel mockIrm) = _deployWithMockRate();
        mockIrm.setRate(type(uint128).max);
        _forward(1 days);
        uint256 cappedInterest = uint256(7_000e6).wMulDown(ConstantsLib.MAX_BORROW_RATE.wTaylorCompounded(1 days));

        // when, then
        vm.expectEmit(address(mockMarket));
        emit EventsLib.AccrueInterest(
            ConstantsLib.MAX_BORROW_RATE, cappedInterest, cappedInterest.mulDivUp(RESERVE_FACTOR, 1e18)
        );
        mockMarket.accrueInterest();

        // then
        assertEq(mockMarket.marketState().totalBorrowAssets, 7_000e6 + cappedInterest);
        // 연 200% 의 하루치는 1% 미만
        assertLt(cappedInterest, 70e6);
    }

    /// @dev 금리 모델이 revert 하면 이자 반영 중단
    function test_AccrueInterest_RevertWhen_RateModelIsDown() public {
        // given
        (Market mockMarket, MockRateModel mockIrm) = _deployWithMockRate();
        mockIrm.setDown(true);
        _forward(1 days);

        // when, then
        vm.expectRevert(MockRateModel.RateModelDown.selector);
        mockMarket.accrueInterest();
    }

    /// @dev 뷰의 장부와 반영 뒤 장부 일치
    function testFuzz_AccrueInterest_ExpectedStateMatchesStored(uint256 borrowed, uint256 elapsed) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        elapsed = bound(elapsed, 0, 5 * 365 days);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);
        _forward(elapsed);
        MarketState memory expected = market.expectedMarketState();
        uint256 expectedTotalAssets = market.totalAssets();
        uint256 expectedDebt = market.debtOf(BORROWER);

        // when
        market.accrueInterest();

        // then
        assertEq(abi.encode(market.marketState()), abi.encode(expected));
        assertEq(market.marketState().totalSupplyAssets, expectedTotalAssets);
        assertEq(market.debtOf(BORROWER), expectedDebt);
    }

    /// @dev 이자 반영 뒤에도 잔액 + 총 차입 = 총 예치 + 준비금
    function testFuzz_AccrueInterest_KeepsLedgerBalanced(uint256 borrowed, uint256 elapsed) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        elapsed = bound(elapsed, 0, 5 * 365 days);
        _deposit(SUPPLIER, 8_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);
        _forward(elapsed);

        // when
        market.accrueInterest();

        // then
        MarketState memory state = market.marketState();
        assertEq(
            loanToken.balanceOf(address(market)) + state.totalBorrowAssets,
            uint256(state.totalSupplyAssets) + state.reserve
        );
        assertLe(state.totalBorrowAssets, uint256(state.totalSupplyAssets) + state.reserve);
    }

    /// @dev 나눠 반영한 이자가 한 번에 반영한 이자 이상
    function testFuzz_AccrueInterest_SplitAccrualNeverLessThanSingle(uint256 elapsed) public {
        // given
        elapsed = bound(elapsed, 2, 365 days);
        _setUpExample();
        uint256 snapshot = vm.snapshotState();
        _forward(elapsed);
        market.accrueInterest();
        uint256 single = market.marketState().totalBorrowAssets;
        vm.revertToState(snapshot);
        _forward(elapsed / 2);
        market.accrueInterest();
        _forward(elapsed - elapsed / 2);

        // when
        market.accrueInterest();

        // then
        uint256 split = market.marketState().totalBorrowAssets;
        assertGe(split + 1, single);
    }

    /// @dev 이자 0 이 되는 짧은 간격의 반복 반영에서도 이자가 쌓임
    function test_AccrueInterest_EverySecondStillAccrues() public {
        // given
        _setUpSmallMarket();
        uint256 single = _interestAfter(3600);
        uint256 borrowBefore = market.marketState().totalBorrowAssets;

        // when
        for (uint256 i; i < 3600; ++i) {
            _forward(1);
            market.accrueInterest();
        }

        // then
        uint256 split = market.marketState().totalBorrowAssets - borrowBefore;
        assertGt(split, 0);
        assertGe(split + 1, single);
    }

    /// @dev 12초마다 반영한 이자가 한 번에 반영한 이자보다 작지 않음
    function test_AccrueInterest_Every12sNotLessThanSingle() public {
        // given
        _setUpSmallMarket();
        uint256 single = _interestAfter(1 days);
        uint256 borrowBefore = market.marketState().totalBorrowAssets;

        // when
        for (uint256 i; i < 1 days / 12; ++i) {
            _forward(12);
            market.accrueInterest();
        }

        // then
        assertGe(market.marketState().totalBorrowAssets - borrowBefore + 1, single);
    }

    /// @dev 이용률 90%, 총 차입 200 USDC 의 작은 시장
    function _setUpSmallMarket() internal {
        _deposit(SUPPLIER, 222_222_223);
        _supplyCollateral(BORROWER, 1e18);
        _borrow(BORROWER, MIN_DEBT);
    }

    /// @dev 한 번에 반영했을 때의 이자. 상태는 되돌림
    function _interestAfter(uint256 total) internal returns (uint256 interest) {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowBefore = market.marketState().totalBorrowAssets;
        _forward(total);
        market.accrueInterest();
        interest = market.marketState().totalBorrowAssets - borrowBefore;
        vm.revertToState(snapshot);
    }

    /* 장부 변경 전 이자 반영 */

    function _assertAccruedNow() internal view {
        MarketState memory state = market.marketState();
        assertEq(state.lastUpdate, block.timestamp);
        assertGt(state.totalBorrowAssets, 7_000e6);
    }

    function test_SupplyCollateral_AccruesInterestFirst() public {
        // given
        _setUpExample();
        _forward(1 days);

        // when
        _supplyCollateral(BORROWER, 1e18);

        // then
        _assertAccruedNow();
    }

    function test_WithdrawCollateral_AccruesInterestFirst() public {
        // given
        _setUpExample();
        _forward(1 days);

        // when
        vm.prank(BORROWER);
        market.withdrawCollateral(0.1e18, BORROWER, BORROWER);

        // then
        _assertAccruedNow();
    }

    function test_Withdraw_AccruesInterestFirst() public {
        // given
        _setUpExample();
        _forward(1 days);

        // when
        vm.prank(SUPPLIER);
        market.withdraw(100e6, SUPPLIER, SUPPLIER);

        // then
        _assertAccruedNow();
    }

    function test_Redeem_AccruesInterestFirst() public {
        // given
        _setUpExample();
        _forward(1 days);

        // when
        vm.prank(SUPPLIER);
        market.redeem(100e6 * 1e6, SUPPLIER, SUPPLIER);

        // then
        _assertAccruedNow();
    }
}
