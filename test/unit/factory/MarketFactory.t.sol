// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WAD} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "../../../src/Market.sol";
import {MarketFactory} from "../../../src/MarketFactory.sol";
import {KinkedRateModel} from "../../../src/KinkedRateModel.sol";
import {IMarket, MarketParams} from "../../../src/interfaces/IMarket.sol";
import {IMarketFactory} from "../../../src/interfaces/IMarketFactory.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockOracleAdapter} from "../../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../../BaseTest.sol";

contract MarketFactoryTest is BaseTest {
    address internal OWNER = makeAddr("owner");

    MarketFactory internal factory;

    function setUp() public override {
        super.setUp();
        factory = new MarketFactory(OWNER);
        vm.startPrank(OWNER);
        factory.enableLltv(LLTV);
        factory.enableIrm(address(irm));
        factory.enableOracle(address(oracle));
        vm.stopPrank();
    }

    /* 승인 목록 */

    function test_EnableLltv_SetsFlagAndEmits() public {
        // given
        MarketFactory fresh = new MarketFactory(OWNER);

        // when, then
        vm.expectEmit(address(fresh));
        emit EventsLib.EnableLltv(0.8e18);
        vm.prank(OWNER);
        fresh.enableLltv(0.8e18);

        // then
        assertTrue(fresh.isLltvEnabled(0.8e18));
        assertFalse(fresh.isLltvEnabled(LLTV));
    }

    function test_EnableIrm_SetsFlagAndEmits() public {
        // given
        MarketFactory fresh = new MarketFactory(OWNER);

        // when, then
        vm.expectEmit(address(fresh));
        emit EventsLib.EnableIrm(address(irm));
        vm.prank(OWNER);
        fresh.enableIrm(address(irm));

        // then
        assertTrue(fresh.isIrmEnabled(address(irm)));
    }

    function test_EnableOracle_SetsFlagAndEmits() public {
        // given
        MarketFactory fresh = new MarketFactory(OWNER);

        // when, then
        vm.expectEmit(address(fresh));
        emit EventsLib.EnableOracle(address(oracle));
        vm.prank(OWNER);
        fresh.enableOracle(address(oracle));

        // then
        assertTrue(fresh.isOracleEnabled(address(oracle)));
    }

    function test_EnableLltv_RevertWhen_NotOwner() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.enableLltv(0.5e18);
    }

    function test_EnableIrm_RevertWhen_NotOwner() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.enableIrm(address(loanToken));
    }

    function test_EnableOracle_RevertWhen_NotOwner() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.enableOracle(address(loanToken));
    }

    function test_EnableLltv_RevertWhen_AlreadyEnabled() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(IMarketFactory.AlreadyEnabled.selector);
        factory.enableLltv(LLTV);
    }

    function test_EnableIrm_RevertWhen_AlreadyEnabled() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(IMarketFactory.AlreadyEnabled.selector);
        factory.enableIrm(address(irm));
    }

    function test_EnableOracle_RevertWhen_AlreadyEnabled() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(IMarketFactory.AlreadyEnabled.selector);
        factory.enableOracle(address(oracle));
    }

    function test_EnableLltv_RevertWhen_NotBelowWad() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.LltvTooHigh.selector, WAD));
        factory.enableLltv(WAD);
    }

    function test_EnableLltv_AcceptsJustBelowWad() public {
        // when
        vm.prank(OWNER);
        factory.enableLltv(WAD - 1);

        // then
        assertTrue(factory.isLltvEnabled(WAD - 1));
    }

    function test_EnableIrm_RevertWhen_NoCode() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NoCode.selector, OTHER));
        factory.enableIrm(OTHER);
    }

    function test_EnableOracle_RevertWhen_NoCode() public {
        // when, then
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.NoCode.selector, OTHER));
        factory.enableOracle(OTHER);
    }

    /// @dev 소유권을 OTHER 에게 넘긴 뒤 OTHER 가 포기
    function _renounceOwnership() internal {
        vm.prank(OWNER);
        factory.transferOwnership(OTHER);
        vm.startPrank(OTHER);
        factory.acceptOwnership();
        factory.renounceOwnership();
        vm.stopPrank();
    }

    /// @dev 넘겨받을 쪽의 수락 전까지 소유자 유지
    function test_TransferOwnership_KeepsOwnerUntilAccepted() public {
        // when
        vm.prank(OWNER);
        factory.transferOwnership(OTHER);

        // then
        assertEq(factory.owner(), OWNER);
    }

    function test_AcceptOwnership_ChangesOwner() public {
        // given
        vm.prank(OWNER);
        factory.transferOwnership(OTHER);

        // when
        vm.prank(OTHER);
        factory.acceptOwnership();

        // then
        assertEq(factory.owner(), OTHER);
    }

    function test_RenounceOwnership_ClearsOwner() public {
        // given
        vm.prank(OWNER);
        factory.transferOwnership(OTHER);
        vm.prank(OTHER);
        factory.acceptOwnership();

        // when
        vm.prank(OTHER);
        factory.renounceOwnership();

        // then
        assertEq(factory.owner(), address(0));
    }

    /// @dev 소유권 포기 뒤 승인 목록 고정
    function test_EnableLltv_RevertWhen_OwnershipRenounced() public {
        // given
        _renounceOwnership();

        // when, then
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        factory.enableLltv(0.5e18);
    }

    /// @dev 소유권 포기 뒤에도 이미 승인된 값으로 시장 생성 가능
    function test_CreateMarket_WorksAfterOwnershipRenounced() public {
        // given
        _renounceOwnership();

        // when
        address created = factory.createMarket(params);

        // then
        assertTrue(factory.isMarket(created));
    }

    /* createMarket */

    function test_CreateMarket_DeploysAtComputedAddress() public {
        // given
        address expected = factory.computeMarketAddress(params);
        assertEq(expected.code.length, 0);
        assertFalse(factory.isMarket(expected));

        // when, then
        vm.expectEmit(address(factory));
        emit EventsLib.CreateMarket(expected, OTHER, params);
        vm.prank(OTHER);
        address created = factory.createMarket(params);

        // then
        assertEq(created, expected);
        assertTrue(factory.isMarket(created));
        assertGt(created.code.length, 0);
        MarketParams memory p = Market(created).marketParams();
        assertEq(abi.encode(p), abi.encode(params));
    }

    function test_CreateMarket_DirectDeploymentIsNotRegistered() public view {
        // when, then
        assertFalse(factory.isMarket(address(market)));
    }

    /// @dev 배포된 시장은 바로 사용 가능
    function test_CreateMarket_MarketWorksEndToEnd() public {
        // given
        Market created = Market(factory.createMarket(params));
        loanToken.mint(SUPPLIER, 10_000e6);
        collateralToken.mint(BORROWER, 5e18);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(created), type(uint256).max);
        created.deposit(10_000e6, SUPPLIER);
        vm.stopPrank();
        vm.startPrank(BORROWER);
        collateralToken.approve(address(created), type(uint256).max);
        created.supplyCollateral(5e18, BORROWER);

        // when
        created.borrow(7_000e6, BORROWER, BORROWER);
        vm.stopPrank();

        // then
        assertEq(created.debtOf(BORROWER), 7_000e6);
        assertEq(loanToken.balanceOf(address(factory)), 0);
    }

    /// @dev 같은 파라미터의 시장은 하나
    function test_CreateMarket_RevertWhen_AlreadyCreated() public {
        // given
        address created = factory.createMarket(params);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.MarketAlreadyCreated.selector, created));
        factory.createMarket(params);
    }

    function test_CreateMarket_DifferentParamsGiveDifferentMarkets() public {
        // given
        address first = factory.createMarket(params);
        MarketParams memory p = params;
        p.minDebt = MIN_DEBT + 1;

        // when
        address second = factory.createMarket(p);

        // then
        assertTrue(first != second);
        assertTrue(factory.isMarket(second));
    }

    function test_CreateMarket_RevertWhen_LltvNotEnabled() public {
        // given
        MarketParams memory p = params;
        p.lltv = 0.9e18;

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.LltvNotEnabled.selector, p.lltv));
        factory.createMarket(p);
    }

    function test_CreateMarket_RevertWhen_IrmNotEnabled() public {
        // given
        MarketParams memory p = params;
        p.irm = address(new KinkedRateModel(OPTIMAL_UTILIZATION, BASE_RATE, SLOPE_1, SLOPE_2));

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.IrmNotEnabled.selector, p.irm));
        factory.createMarket(p);
    }

    function test_CreateMarket_RevertWhen_OracleNotEnabled() public {
        // given
        MarketParams memory p = params;
        p.oracle = address(new MockOracleAdapter(address(loanToken), address(collateralToken)));

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.OracleNotEnabled.selector, p.oracle));
        factory.createMarket(p);
    }

    /// @dev 승인된 오라클도 다른 담보 토큰에는 사용 불가
    function test_CreateMarket_RevertWhen_OracleCollateralTokenMismatch() public {
        // given
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MarketParams memory p = params;
        p.collateralToken = address(wbtc);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.OracleTokenMismatch.selector, p.oracle));
        factory.createMarket(p);
    }

    /// @dev 승인된 오라클도 다른 대출 토큰에는 사용 불가
    function test_CreateMarket_RevertWhen_OracleLoanTokenMismatch() public {
        // given
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MarketParams memory p = params;
        p.loanToken = address(wbtc);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarketFactory.OracleTokenMismatch.selector, p.oracle));
        factory.createMarket(p);
    }

    /// @dev Market 생성자가 거절하면 등록도 되돌림
    function test_CreateMarket_RevertWhen_MarketConstructorRejectsMinDebt() public {
        // given
        MarketParams memory p = params;
        p.minDebt = 0;

        // when, then
        vm.expectRevert(IMarket.ZeroMinDebt.selector);
        factory.createMarket(p);

        // then
        assertFalse(factory.isMarket(factory.computeMarketAddress(p)));
    }

    function test_CreateMarket_RevertWhen_MarketConstructorRejectsReserveFactor() public {
        // given
        MarketParams memory p = params;
        p.reserveFactor = ConstantsLib.MAX_RESERVE_FACTOR + 1;

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarket.ReserveFactorTooHigh.selector, p.reserveFactor));
        factory.createMarket(p);
    }

    /// @dev 등록된 시장은 승인된 값만 갖고 계산한 주소에 위치
    function testFuzz_CreateMarket_RegisteredMarketsUseEnabledValues(
        uint256 lltv,
        uint256 minDebt,
        uint256 reserveFactor,
        bool useEnabledLltv
    ) public {
        // given
        lltv = useEnabledLltv ? LLTV : bound(lltv, 0, WAD);
        minDebt = bound(minDebt, 0, 1e12);
        reserveFactor = bound(reserveFactor, 0, WAD);
        MarketParams memory p = params;
        p.lltv = lltv;
        p.minDebt = minDebt;
        p.reserveFactor = reserveFactor;
        address expected = factory.computeMarketAddress(p);

        // when, then
        try factory.createMarket(p) returns (address created) {
            assertEq(created, expected);
            assertTrue(factory.isMarket(created));
            assertTrue(factory.isLltvEnabled(Market(created).LLTV()));
            assertTrue(factory.isIrmEnabled(address(Market(created).IRM())));
            assertTrue(factory.isOracleEnabled(address(Market(created).ORACLE())));
            assertGt(Market(created).MIN_DEBT(), 0);
            assertLe(Market(created).RESERVE_FACTOR(), ConstantsLib.MAX_RESERVE_FACTOR);
        } catch {
            assertFalse(factory.isMarket(expected));
            assertEq(expected.code.length, 0);
        }
    }
}
