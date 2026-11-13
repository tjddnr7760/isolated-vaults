// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {WAD} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "../../../src/Market.sol";
import {IMarket, MarketParams, MarketState} from "../../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {BaseTest} from "../../BaseTest.sol";

contract ConstructorTest is BaseTest {
    function test_Constructor_SetsParams() public view {
        // when
        MarketParams memory p = market.marketParams();

        // then
        assertEq(p.loanToken, address(loanToken));
        assertEq(p.collateralToken, address(collateralToken));
        assertEq(p.oracle, address(oracle));
        assertEq(p.irm, address(irm));
        assertEq(p.lltv, LLTV);
        assertEq(p.minDebt, MIN_DEBT);
        assertEq(p.reserveFactor, RESERVE_FACTOR);

        assertEq(market.asset(), address(loanToken));
        assertEq(market.COLLATERAL_TOKEN(), address(collateralToken));
        assertEq(address(market.ORACLE()), address(oracle));
        assertEq(address(market.IRM()), address(irm));
        assertEq(market.LLTV(), LLTV);
        assertEq(market.MIN_DEBT(), MIN_DEBT);
        assertEq(market.RESERVE_FACTOR(), RESERVE_FACTOR);
    }

    function test_Constructor_StartsLastUpdateAtDeployTime() public view {
        // when
        MarketState memory state = market.marketState();

        // then
        // lastUpdate 는 0 이 아닌 배포 시각
        assertEq(state.lastUpdate, block.timestamp);
        assertEq(state.totalSupplyAssets, 0);
        assertEq(state.totalBorrowAssets, 0);
        assertEq(state.totalBorrowShares, 0);
        assertEq(state.reserve, 0);
    }

    function test_Constructor_ShareDecimalsAreAssetDecimalsPlusOffset() public view {
        // when, then
        assertEq(market.decimals(), 6 + ConstantsLib.DECIMALS_OFFSET);
    }

    function test_Constructor_LiquidationIncentiveFactor() public view {
        // when, then
        // 1 ÷ (1 − 0.3 × (1 − 0.86)) = 1 ÷ 0.958, 내림
        assertEq(market.liquidationIncentiveFactor(), uint256(1e36) / 0.958e18);
    }

    function test_Constructor_RevertWhen_LoanTokenZero() public {
        // given
        MarketParams memory p = params;
        p.loanToken = address(0);

        // when, then
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_CollateralTokenZero() public {
        // given
        MarketParams memory p = params;
        p.collateralToken = address(0);

        // when, then
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_OracleZero() public {
        // given
        MarketParams memory p = params;
        p.oracle = address(0);

        // when, then
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_IrmZero() public {
        // given
        MarketParams memory p = params;
        p.irm = address(0);

        // when, then
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_IdenticalTokens() public {
        // given
        MarketParams memory p = params;
        p.collateralToken = p.loanToken;

        // when, then
        vm.expectRevert(IMarket.IdenticalTokens.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_LltvTooHigh() public {
        // given
        MarketParams memory p = params;
        p.lltv = WAD;

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarket.LltvTooHigh.selector, WAD));
        new Market(p);
    }

    function test_Constructor_AcceptsLltvJustBelowWad() public {
        // given
        MarketParams memory p = params;
        p.lltv = WAD - 1;

        // when
        Market created = new Market(p);

        // then
        assertEq(created.LLTV(), WAD - 1);
    }

    function test_Constructor_RevertWhen_ZeroMinDebt() public {
        // given
        MarketParams memory p = params;
        p.minDebt = 0;

        // when, then
        vm.expectRevert(IMarket.ZeroMinDebt.selector);
        new Market(p);
    }

    function test_Constructor_RevertWhen_ReserveFactorTooHigh() public {
        // given
        MarketParams memory p = params;
        p.reserveFactor = ConstantsLib.MAX_RESERVE_FACTOR + 1;

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarket.ReserveFactorTooHigh.selector, p.reserveFactor));
        new Market(p);
    }

    function test_Constructor_AcceptsMaxReserveFactor() public {
        // given
        MarketParams memory p = params;
        p.reserveFactor = ConstantsLib.MAX_RESERVE_FACTOR;

        // when
        Market created = new Market(p);

        // then
        assertEq(created.RESERVE_FACTOR(), ConstantsLib.MAX_RESERVE_FACTOR);
    }
}
