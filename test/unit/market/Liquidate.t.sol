// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

import {IMarket, MarketState, Position} from "../../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {CallbackLiquidator} from "../../mocks/CallbackLiquidator.sol";
import {MockOracleAdapter} from "../../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../../BaseTest.sol";

contract LiquidateTest is BaseTest {
    using MathLib for uint256;

    uint256 internal lif;

    function setUp() public override {
        super.setUp();
        // 예치 10,000, 담보 5 WETH, 차입 7,000, 가격 2,000
        _setUpExample();
        loanToken.mint(LIQUIDATOR, 100_000e6);
        lif = market.liquidationIncentiveFactor();
    }

    function _quote(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(collateral, price, ConstantsLib.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
    }

    /* 검사 */

    function test_Liquidate_RevertWhen_Healthy() public {
        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarket.HealthyPosition.selector);
        market.liquidate(BORROWER, 1e18, 0, "");
    }

    function test_Liquidate_RevertWhen_NoDebt() public {
        // given
        _supplyCollateral(OTHER, 1e18);
        oracle.setPrice(1);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarket.HealthyPosition.selector);
        market.liquidate(OTHER, 1e18, 0, "");
    }

    function test_Liquidate_RevertWhen_BothInputsZero() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarket.InconsistentInput.selector);
        market.liquidate(BORROWER, 0, 0, "");
    }

    function test_Liquidate_RevertWhen_BothInputsNonZero() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarket.InconsistentInput.selector);
        market.liquidate(BORROWER, 1e18, 1e12, "");
    }

    function test_Liquidate_RevertWhen_OracleIsDown() public {
        // given
        oracle.setPrice(PRICE_1600);
        oracle.setDown(true);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(MockOracleAdapter.OracleDown.selector);
        market.liquidate(BORROWER, 1e18, 0, "");
    }

    /// @dev 5 WETH 로 빚 7,000 을 딱 감당하는 가장 낮은 가격, 약 1,627.9
    function _lowestHealthyPrice() internal pure returns (uint256 price, uint256 step) {
        step = 1e17;
        price = uint256(7_000e6) * 1e18 / LLTV * 1e36 / 5e18 / step * step;
        while (_maxBorrow(5e18, price) < 7_000e6) price += step;
        while (_maxBorrow(5e18, price - step) >= 7_000e6) price -= step;
    }

    /// @dev 가격이 빚을 딱 감당하면 건강
    function test_Liquidate_RevertWhen_PriceExactlyCoversDebt() public {
        // given
        (uint256 price,) = _lowestHealthyPrice();
        oracle.setPrice(price);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarket.HealthyPosition.selector);
        market.liquidate(BORROWER, 1e18, 0, "");
    }

    /// @dev 가격이 경계 바로 아래면 청산 가능
    function test_Liquidate_PriceJustBelowHealthBoundary() public {
        // given
        (uint256 price, uint256 step) = _lowestHealthyPrice();
        oracle.setPrice(price - step);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 1e18, 0, "");

        // then
        assertEq(market.position(BORROWER).collateral, 4e18);
    }

    /* 담보량 지정 */

    function test_Liquidate_BySeizedAssets() public {
        // given
        oracle.setPrice(PRICE_1600);
        uint256 seized = 1e18;
        // 1 WETH = 1,600 USDC 를 LIF 로 나눈 값
        uint256 expectedRepaid = _quote(seized, PRICE_1600).wDivUp(lif);
        uint256 liquidatorLoanBefore = loanToken.balanceOf(LIQUIDATOR);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seizedReturned, uint256 repaid) = market.liquidate(BORROWER, seized, 0, "");

        // then
        assertEq(seizedReturned, seized);
        assertApproxEqAbs(repaid, expectedRepaid, 1);
        assertGe(repaid, expectedRepaid);
        assertEq(collateralToken.balanceOf(LIQUIDATOR), seized);
        assertEq(liquidatorLoanBefore - loanToken.balanceOf(LIQUIDATOR), repaid);
        assertEq(market.position(BORROWER).collateral, 4e18);
        assertApproxEqAbs(market.debtOf(BORROWER), 7_000e6 - repaid, 1);
        // 부실이 없어 예치자 몫 유지
        assertEq(market.marketState().totalSupplyAssets, 10_000e6);
    }

    /* 지분 지정 */

    function test_Liquidate_ByRepaidShares() public {
        // given
        oracle.setPrice(PRICE_1600);
        // 빚 3,000 어치 지분
        uint256 repaidShares = 3_000e6 * 1e6;
        // 3,000 × LIF 어치 담보
        uint256 expectedSeized =
            Math.mulDiv(uint256(3_000e6).wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE_1600);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = market.liquidate(BORROWER, 0, repaidShares, "");

        // then
        assertEq(repaid, 3_000e6);
        assertEq(seized, expectedSeized);
        assertEq(market.debtOf(BORROWER), 4_000e6);
        assertEq(market.position(BORROWER).collateral, 5e18 - expectedSeized);
        // 청산 뒤 다시 건강
        assertTrue(market.isHealthy(BORROWER));
    }

    /// @dev 담보 전부 지정 시 빚보다 많이 갚게 되어 거절
    function test_Liquidate_RevertWhen_SeizedPathRepaysMoreThanDebt() public {
        // given
        oracle.setPrice(PRICE_1600);
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        uint256 repaidShares = _quote(5e18, PRICE_1600).wDivUp(lif) * 1e6;

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.RepaidSharesExceedDebt.selector, repaidShares, borrowShares));
        market.liquidate(BORROWER, 5e18, 0, "");
    }

    /// @dev 빚 전부 지정 시 담보보다 많이 가져가게 되어 거절
    function test_Liquidate_RevertWhen_SharesPathSeizesMoreThanCollateral() public {
        // given
        oracle.setPrice(PRICE_1000);
        uint256 seized = Math.mulDiv(uint256(7_000e6).wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE_1000);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.SeizedExceedsCollateral.selector, seized, 5e18));
        market.liquidate(BORROWER, 0, 7_000e6 * 1e6, "");
    }

    /* 입력 낮추기 */

    /// @dev 큰 값 입력 시 담보 전부 청산
    function test_Liquidate_SeizedAboveCollateralMeansAll() public {
        // given
        oracle.setPrice(PRICE_1000);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized,) = market.liquidate(BORROWER, type(uint256).max, 0, "");

        // then
        assertEq(seized, 5e18);
        assertEq(collateralToken.balanceOf(LIQUIDATOR), 5e18);
        Position memory pos = market.position(BORROWER);
        assertEq(pos.collateral, 0);
        assertEq(pos.borrowShares, 0);
    }

    /// @dev 큰 값 입력 시 빚 전부 청산
    function test_Liquidate_SharesAboveDebtMeansAll() public {
        // given
        oracle.setPrice(PRICE_1600);
        uint256 expectedSeized =
            Math.mulDiv(uint256(7_000e6).wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE_1600);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = market.liquidate(BORROWER, 0, type(uint256).max, "");

        // then
        assertEq(repaid, 7_000e6);
        assertEq(seized, expectedSeized);
        Position memory pos = market.position(BORROWER);
        assertEq(pos.borrowShares, 0);
        assertEq(pos.collateral, 5e18 - expectedSeized);
    }

    /* 작은 잔액 금지 */

    /// @dev 남은 빚이 최소 부채 미만이면 거절
    function test_Liquidate_RevertWhen_LeavesDebtBelowMinimum() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DebtBelowMinimum.selector, MIN_DEBT - 1, MIN_DEBT));
        market.liquidate(BORROWER, 0, (7_000e6 - MIN_DEBT + 1) * 1e6, "");
    }

    /// @dev 남은 빚이 정확히 최소 부채면 통과
    function test_Liquidate_LeavesDebtExactlyMinimum() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 0, (7_000e6 - MIN_DEBT) * 1e6, "");

        // then
        assertEq(market.debtOf(BORROWER), MIN_DEBT);
    }

    /// @dev 빚이 남는데 남은 담보 가치가 최소 부채 미만이면 거절
    function test_Liquidate_RevertWhen_LeavesCollateralBelowMinimum() public {
        // given
        oracle.setPrice(PRICE_1000);
        // 남는 담보 0.2 WETH − 1 wei, 가치는 200 USDC − 1
        uint256 seized = 4.8e18 + 1;

        // when, then
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.CollateralBelowMinimum.selector, MIN_DEBT - 1, MIN_DEBT));
        market.liquidate(BORROWER, seized, 0, "");
    }

    /// @dev 남은 담보 가치가 정확히 최소 부채면 통과
    function test_Liquidate_LeavesCollateralExactlyMinimum() public {
        // given
        oracle.setPrice(PRICE_1000);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 4.8e18, 0, "");

        // then
        Position memory pos = market.position(BORROWER);
        assertEq(pos.collateral, 0.2e18);
        assertGt(pos.borrowShares, 0);
        assertEq(market.marketState().totalSupplyAssets, 10_000e6);
    }

    /// @dev 빚이 0 이면 남은 담보가 작아도 통과
    function test_Liquidate_NoDebtLeftAllowsSmallCollateral() public {
        // given
        // 담보 가치 7,350, 전부 청산 뒤 약 43 USDC 어치 남음
        uint256 price = PRICE_1000 * 147 / 100;
        oracle.setPrice(price);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 0, type(uint256).max, "");

        // then
        Position memory pos = market.position(BORROWER);
        assertEq(pos.borrowShares, 0);
        uint256 leftValue = Math.mulDiv(pos.collateral, price, ConstantsLib.ORACLE_PRICE_SCALE);
        assertGt(leftValue, 0);
        assertLt(leftValue, MIN_DEBT);
    }

    /// @dev 어떤 금액과 가격의 청산에도 작은 잔액 없음
    function testFuzz_Liquidate_NeverLeavesDust(uint256 amount, uint256 price, uint256 elapsed, bool bySeized) public {
        // given
        _forward(bound(elapsed, 0, 365 days));
        price = bound(price, PRICE_1000 / 4, PRICE_1600);
        oracle.setPrice(price);
        Position memory pos = market.position(BORROWER);

        // when
        if (bySeized) {
            uint256 debt = market.debtOf(BORROWER);
            uint256 maxSeizable = Math.min(pos.collateral, Math.mulDiv((debt * 99 / 100).wMulDown(lif), 1e36, price));
            _liquidateOrFully(LIQUIDATOR, BORROWER, bound(amount, 1e12, maxSeizable), 0);
        } else {
            // 담보 가치의 99% 로 갚을 수 있는 빚의 지분 환산
            uint256 maxAssets = Math.mulDiv(pos.collateral, price, 1e36).wDivDown(lif) * 99 / 100;
            uint256 maxShares = Math.mulDiv(maxAssets, pos.borrowShares, market.debtOf(BORROWER));
            maxShares = Math.min(maxShares, pos.borrowShares);
            _liquidateOrFully(LIQUIDATOR, BORROWER, 0, bound(amount, 1e12, maxShares));
        }

        // then
        pos = market.position(BORROWER);
        if (pos.borrowShares != 0) {
            assertGe(market.debtOf(BORROWER), MIN_DEBT);
            assertGe(Math.mulDiv(pos.collateral, price, ConstantsLib.ORACLE_PRICE_SCALE), MIN_DEBT);
        }
        if (pos.collateral == 0) assertEq(pos.borrowShares, 0);
    }

    /// @dev 받은 담보 가치가 갚은 자산 × LIF 이하
    function testFuzz_Liquidate_IncentiveNeverExceedsFactor(uint256 seized, uint256 price, bool bySeized) public {
        // given
        price = bound(price, PRICE_1000, PRICE_1600);
        oracle.setPrice(price);
        // 빚의 99% 어치 담보까지 선택
        uint256 maxSeizable = Math.min(5e18, Math.mulDiv(uint256(6_930e6).wMulDown(lif), 1e36, price));
        seized = bound(seized, 1e12, maxSeizable);
        uint256 borrowShares = market.position(BORROWER).borrowShares;

        // when
        // 작은 잔액이 남으면 전부 청산
        uint256 repaid;
        if (bySeized) {
            (seized, repaid) = _liquidateOrFully(LIQUIDATOR, BORROWER, seized, 0);
        } else {
            uint256 shares = Math.mulDiv(_quote(seized, price), 1e18, lif) * 1e6;
            shares = Math.min(shares, borrowShares);
            (seized, repaid) = _liquidateOrFully(LIQUIDATOR, BORROWER, 0, shares);
        }

        // then
        // 받은 담보 가치 ≤ 갚은 자산 × LIF + 1 wei
        assertLe(Math.mulDiv(seized, price, ConstantsLib.ORACLE_PRICE_SCALE), repaid.wMulDown(lif) + 1);
    }

    /* 부실 채무 */

    /// @dev 준비금이 없으면 남은 빚 전부를 예치자 몫에서 차감
    function test_Liquidate_BadDebtSocializedWhenNoReserve() public {
        // given
        oracle.setPrice(PRICE_1000);
        // 담보 5 WETH = 5,000, 갚을 자산 = 5,000 ÷ LIF
        uint256 expectedRepaid = uint256(5_000e6).wDivUp(lif);
        uint256 expectedBadDebt = 7_000e6 - expectedRepaid;

        // when
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = market.liquidate(BORROWER, 5e18, 0, "");

        // then
        assertApproxEqAbs(repaid, expectedRepaid, 1);
        Position memory pos = market.position(BORROWER);
        assertEq(pos.collateral, 0);
        assertEq(pos.borrowShares, 0);
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowAssets, 0);
        assertEq(state.totalBorrowShares, 0);
        assertEq(state.reserve, 0);
        assertApproxEqAbs(state.totalSupplyAssets, 10_000e6 - expectedBadDebt, 1);
        // 장부의 현금이 실제 잔액과 일치
        assertEq(loanToken.balanceOf(address(market)), state.totalSupplyAssets);
    }

    /// @dev 준비금이 먼저 흡수, 모자라는 만큼만 예치자 몫에서 차감
    function test_Liquidate_BadDebtAbsorbedByReserveFirst() public {
        // given
        _forward(365 days);
        market.accrueInterest();
        MarketState memory beforeState = market.marketState();
        assertGt(beforeState.reserve, 0);
        oracle.setPrice(PRICE_1000);

        // when
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = market.liquidate(BORROWER, 5e18, 0, "");

        // then
        MarketState memory afterState = market.marketState();
        uint256 badDebt = beforeState.totalBorrowAssets - repaid;
        assertGt(badDebt, beforeState.reserve);
        assertEq(afterState.reserve, 0);
        assertEq(afterState.totalSupplyAssets, beforeState.totalSupplyAssets - (badDebt - beforeState.reserve));
        assertEq(afterState.totalBorrowAssets, 0);
        assertEq(afterState.totalBorrowShares, 0);
    }

    /// @dev 준비금이 부실보다 크면 예치자 몫 유지
    function test_Liquidate_BadDebtFullyCoveredByReserve() public {
        // given
        _forward(365 days);
        market.accrueInterest();
        uint256 reserve = market.marketState().reserve;
        // 남는 빚이 준비금보다 작아지는 가격 선택
        uint256 debt = market.debtOf(BORROWER);
        uint256 price;
        // 부실이 준비금의 절반쯤 되는 가격
        price = Math.mulDiv((debt - reserve / 2).wMulDown(lif), 1e36, 5e18);
        oracle.setPrice(price);
        uint256 supplyBefore = market.marketState().totalSupplyAssets;

        // when
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = market.liquidate(BORROWER, 5e18, 0, "");

        // then
        MarketState memory afterState = market.marketState();
        uint256 badDebt = debt - repaid;
        assertGt(badDebt, 0);
        assertEq(afterState.totalSupplyAssets, supplyBefore);
        assertEq(afterState.reserve, reserve - badDebt);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }

    /// @dev 청산 뒤 담보가 0 이면 빚도 0
    function testFuzz_Liquidate_CollateralZeroImpliesNoDebt(uint256 seized, uint256 price, uint256 elapsed) public {
        // given
        elapsed = bound(elapsed, 0, 365 days);
        _forward(elapsed);
        price = bound(price, PRICE_1000 / 4, PRICE_1600);
        oracle.setPrice(price);
        uint256 debt = market.debtOf(BORROWER);
        uint256 maxSeizable = Math.min(5e18, Math.mulDiv((debt * 99 / 100).wMulDown(lif), 1e36, price));
        seized = bound(seized, 1e12, maxSeizable);

        // when
        _liquidateOrFully(LIQUIDATOR, BORROWER, seized, 0);

        // then
        Position memory pos = market.position(BORROWER);
        if (pos.collateral == 0) assertEq(pos.borrowShares, 0);
        MarketState memory state = market.marketState();
        if (state.totalBorrowShares == 0) assertEq(state.totalBorrowAssets, 0);
        // 잔액 + 총 차입 ≥ 총 예치 + 준비금
        assertGe(
            loanToken.balanceOf(address(market)) + state.totalBorrowAssets,
            uint256(state.totalSupplyAssets) + state.reserve
        );
    }

    /* 콜백 */

    /// @dev 담보를 먼저 받고 돈은 나중에 지급
    function test_Liquidate_CallbackReceivesCollateralBeforePaying() public {
        // given
        oracle.setPrice(PRICE_1600);
        CallbackLiquidator callbackLiquidator = new CallbackLiquidator(market);
        assertEq(loanToken.balanceOf(address(callbackLiquidator)), 0);

        // when
        callbackLiquidator.liquidate(BORROWER, 1e18, hex"beef");

        // then
        // 콜백 시점에 담보는 받았고 대출 토큰은 없음
        assertEq(callbackLiquidator.collateralInCallback(), 1e18);
        assertEq(callbackLiquidator.loanBalanceInCallback(), 0);
        assertEq(callbackLiquidator.dataInCallback(), hex"beef");
        uint256 repaid = callbackLiquidator.repaidAssetsInCallback();
        assertApproxEqAbs(repaid, _quote(1e18, PRICE_1600).wDivUp(lif), 1);
        // 청산자는 담보 보유, 마련한 돈은 전부 시장으로 이동
        assertEq(collateralToken.balanceOf(address(callbackLiquidator)), 1e18);
        assertEq(loanToken.balanceOf(address(callbackLiquidator)), 0);
        assertApproxEqAbs(market.debtOf(BORROWER), 7_000e6 - repaid, 1);
    }

    /// @dev data 가 비면 콜백 호출 없음
    function test_Liquidate_NoCallbackWhenDataEmpty() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 1e18, 0, "");

        // then
        assertEq(collateralToken.balanceOf(LIQUIDATOR), 1e18);
    }

    function test_Liquidate_CallbackCannotReenter() public {
        // given
        oracle.setPrice(PRICE_1600);
        CallbackLiquidator callbackLiquidator = new CallbackLiquidator(market);
        callbackLiquidator.setShouldReenter(true);

        // when
        callbackLiquidator.liquidate(BORROWER, 1e18, hex"01");

        // then
        assertEq(callbackLiquidator.reenterSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Liquidate_RevertWhen_CallbackDoesNotPay() public {
        // given
        oracle.setPrice(PRICE_1600);

        // when, then
        // OTHER 는 콜백이 없는 지갑
        vm.prank(OTHER);
        vm.expectRevert();
        market.liquidate(BORROWER, 1e18, 0, hex"01");

        // then
        assertEq(market.position(BORROWER).collateral, 5e18);
    }

    /* 이벤트와 상한 */

    /// @dev 이벤트의 갚은 금액, 지분, 담보, 부실 금액, 준비금 사용액 확인
    function test_Liquidate_EmitsBadDebt() public {
        // given
        oracle.setPrice(PRICE_1000);
        // 이자가 없어 지분은 금액의 1e6 배
        uint256 repaid = uint256(5_000e6).wDivUp(lif);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.Liquidate(LIQUIDATOR, BORROWER, repaid, repaid * 1e6, 5e18, 7_000e6 - repaid, 0);
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 5e18, 0, "");
    }

    /// @dev 준비금이 부실보다 작으면 준비금 전부 사용
    function test_Liquidate_EmitsReserveUsed() public {
        // given
        _forward(365 days);
        market.accrueInterest();
        uint256 reserve = market.marketState().reserve;
        assertGt(reserve, 0);
        oracle.setPrice(PRICE_1000);

        // when
        vm.recordLogs();
        vm.prank(LIQUIDATOR);
        (, uint256 repaid) = market.liquidate(BORROWER, 5e18, 0, "");

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != EventsLib.Liquidate.selector) continue;
            (uint256 repaidAssets,, uint256 seizedAssets, uint256 badDebtAssets, uint256 reserveUsed) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertEq(repaidAssets, repaid);
            assertEq(seizedAssets, 5e18);
            assertGt(badDebtAssets, reserve);
            assertEq(reserveUsed, reserve);
            found = true;
        }
        assertTrue(found);
        assertEq(market.marketState().reserve, 0);
    }

    /// @dev 남은 빚이 올림으로 총 차입을 1 넘어도 청산 성공
    function test_Liquidate_BadDebtCappedAtTotalBorrow() public {
        // given
        loanToken.mint(OTHER, 1e6);
        vm.startPrank(OTHER);
        loanToken.approve(address(market), 1e6);
        market.repay(0, 1, BORROWER);
        vm.stopPrank();
        oracle.setPrice(PRICE_1000);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, type(uint256).max, 0, "");

        // then
        MarketState memory state = market.marketState();
        assertEq(state.totalBorrowAssets, 0);
        assertEq(state.totalBorrowShares, 0);
        assertEq(market.position(BORROWER).borrowShares, 0);
    }
}
