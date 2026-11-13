// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WAD} from "morpho-blue/libraries/MathLib.sol";

import {KinkedRateModel} from "../../../src/KinkedRateModel.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";

contract KinkedRateModelTest is Test {
    uint256 internal constant OPTIMAL_UTILIZATION = 0.9e18;
    uint256 internal constant BASE_RATE = uint256(0.01e18) / 365 days;
    uint256 internal constant SLOPE_1 = uint256(0.04e18) / 365 days;
    uint256 internal constant SLOPE_2 = uint256(0.6e18) / 365 days;

    KinkedRateModel internal irm;

    function setUp() public {
        irm = new KinkedRateModel(OPTIMAL_UTILIZATION, BASE_RATE, SLOPE_1, SLOPE_2);
    }

    /* 생성자 */

    function test_Constructor_SetsImmutables() public view {
        // when, then
        assertEq(irm.OPTIMAL_UTILIZATION(), OPTIMAL_UTILIZATION);
        assertEq(irm.BASE_RATE(), BASE_RATE);
        assertEq(irm.SLOPE_1(), SLOPE_1);
        assertEq(irm.SLOPE_2(), SLOPE_2);
    }

    function test_Constructor_RevertWhen_OptimalUtilizationZero() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(KinkedRateModel.InvalidOptimalUtilization.selector, uint256(0)));
        new KinkedRateModel(0, BASE_RATE, SLOPE_1, SLOPE_2);
    }

    function test_Constructor_RevertWhen_OptimalUtilizationFull() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(KinkedRateModel.InvalidOptimalUtilization.selector, WAD));
        new KinkedRateModel(WAD, BASE_RATE, SLOPE_1, SLOPE_2);
    }

    /// @dev 최대 금리가 상한과 같으면 통과
    function test_Constructor_AcceptsMaxRateAtCap() public {
        // given
        uint256 cap = ConstantsLib.MAX_BORROW_RATE;

        // when
        KinkedRateModel atCap = new KinkedRateModel(OPTIMAL_UTILIZATION, 0, cap, 0);

        // then
        assertEq(atCap.SLOPE_1(), cap);
    }

    function test_Constructor_RevertWhen_MaxRateAboveCap() public {
        // given
        uint256 cap = ConstantsLib.MAX_BORROW_RATE;

        // when, then
        vm.expectRevert(abi.encodeWithSelector(KinkedRateModel.RateTooHigh.selector, cap + 1));
        new KinkedRateModel(OPTIMAL_UTILIZATION, 1, cap, 0);
    }

    function test_Constructor_RevertWhen_BaseRateAloneAboveCap() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(KinkedRateModel.RateTooHigh.selector, type(uint256).max));
        new KinkedRateModel(OPTIMAL_UTILIZATION, type(uint256).max, 0, 0);
    }

    /* borrowRate */

    function test_BorrowRate_AtKeyPoints() public view {
        // when, then
        // 이용률 0, 최적 이용률, 100%
        assertEq(irm.borrowRate(1000e6, 0), BASE_RATE);
        assertEq(irm.borrowRate(1000e6, 900e6), BASE_RATE + SLOPE_1);
        assertEq(irm.borrowRate(1000e6, 1000e6), BASE_RATE + SLOPE_1 + SLOPE_2);
        // 최적 이용률의 절반이면 SLOPE_1 의 절반
        assertEq(irm.borrowRate(1000e6, 450e6), BASE_RATE + SLOPE_1 / 2);
        // 최적 이용률과 100% 의 가운데면 SLOPE_2 의 절반
        assertEq(irm.borrowRate(1000e6, 950e6), BASE_RATE + SLOPE_1 + SLOPE_2 / 2);
    }

    function test_BorrowRate_EdgeInputs() public view {
        // when, then
        // 예치 0, 차입 0
        assertEq(irm.borrowRate(0, 0), BASE_RATE);
        // 예치 0 에 차입이 있으면 100%
        assertEq(irm.borrowRate(0, 1), BASE_RATE + SLOPE_1 + SLOPE_2);
        // 차입이 예치를 넘은 상태
        assertEq(irm.borrowRate(1000e6, 1001e6), BASE_RATE + SLOPE_1 + SLOPE_2);
    }

    /// @dev 어떤 입력에도 revert 없이 최대값 이하
    function testFuzz_BorrowRate_NeverRevertsAndBounded(uint256 totalSupplyAssets, uint256 totalBorrowAssets)
        public
        view
    {
        // when
        uint256 rate = irm.borrowRate(totalSupplyAssets, totalBorrowAssets);

        // then
        assertGe(rate, BASE_RATE);
        assertLe(rate, BASE_RATE + SLOPE_1 + SLOPE_2);
        assertLe(rate, ConstantsLib.MAX_BORROW_RATE);
    }

    function testFuzz_BorrowRate_Monotonic(uint128 totalSupplyAssets, uint128 borrowLow, uint128 borrowHigh)
        public
        view
    {
        // given
        if (borrowLow > borrowHigh) (borrowLow, borrowHigh) = (borrowHigh, borrowLow);

        // when, then
        assertLe(irm.borrowRate(totalSupplyAssets, borrowLow), irm.borrowRate(totalSupplyAssets, borrowHigh));
    }

    function testFuzz_BorrowRate_AnyValidCurveNeverReverts(
        uint256 optimalUtilization,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 totalSupplyAssets,
        uint256 totalBorrowAssets
    ) public {
        // given
        optimalUtilization = bound(optimalUtilization, 1, WAD - 1);
        baseRate = bound(baseRate, 0, ConstantsLib.MAX_BORROW_RATE);
        slope1 = bound(slope1, 0, ConstantsLib.MAX_BORROW_RATE - baseRate);
        slope2 = bound(slope2, 0, ConstantsLib.MAX_BORROW_RATE - baseRate - slope1);

        KinkedRateModel anyIrm = new KinkedRateModel(optimalUtilization, baseRate, slope1, slope2);

        // when, then
        assertLe(anyIrm.borrowRate(totalSupplyAssets, totalBorrowAssets), ConstantsLib.MAX_BORROW_RATE);
    }
}
