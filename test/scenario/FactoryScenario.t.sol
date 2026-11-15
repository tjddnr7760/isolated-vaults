// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Market} from "../../src/Market.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {MarketParams, MarketState} from "../../src/interfaces/IMarket.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 팩토리로 만든 시장의 사용과 시장 사이의 격리
contract FactoryScenarioTest is BaseTest {
    // 1 WBTC = 60,000 USDC 가격
    uint256 internal constant PRICE_60000 = 60_000e6 * 1e36 / 1e8;

    address internal OWNER = makeAddr("owner");

    /// @dev 승인 등록 → vault 생성 → 예치 → 대출
    function test_Scenario_CreateMarket_WorksRightAfterCreation() public {
        // given
        MarketFactory factory = new MarketFactory(OWNER);
        vm.startPrank(OWNER);
        factory.enableLltv(LLTV);
        factory.enableIrm(address(irm));
        factory.enableOracle(address(oracle));
        vm.stopPrank();

        // when
        vm.prank(OTHER);
        Market created = Market(factory.createMarket(params));
        loanToken.mint(SUPPLIER, 10_000e6);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(created), type(uint256).max);
        created.deposit(10_000e6, SUPPLIER);
        vm.stopPrank();
        collateralToken.mint(BORROWER, 5e18);
        vm.startPrank(BORROWER);
        collateralToken.approve(address(created), type(uint256).max);
        created.supplyCollateral(5e18, BORROWER);
        created.borrow(7_000e6, BORROWER, BORROWER);
        vm.stopPrank();

        // then
        assertTrue(factory.isMarket(address(created)));
        assertEq(created.debtOf(BORROWER), 7_000e6);
        assertEq(loanToken.balanceOf(BORROWER), 7_000e6);
        assertEq(created.liquidity(), 3_000e6);
    }

    /// @dev vault 두 개 생성 → 한쪽에서 부실 채무
    function test_Scenario_Isolation_BadDebtStaysInItsMarket() public {
        // given
        _setUpExample();
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockOracleAdapter wbtcOracle = new MockOracleAdapter(address(loanToken), address(wbtc));
        wbtcOracle.setPrice(PRICE_60000);
        MarketParams memory otherParams = params;
        otherParams.collateralToken = address(wbtc);
        otherParams.oracle = address(wbtcOracle);
        Market other = _deployMarket(otherParams);
        loanToken.mint(OTHER, 10_000e6);
        vm.prank(OTHER);
        uint256 otherShares = other.deposit(10_000e6, OTHER);
        wbtc.mint(RECEIVER, 1e8);
        vm.startPrank(RECEIVER);
        other.supplyCollateral(1e8, RECEIVER);
        other.borrow(7_000e6, RECEIVER, RECEIVER);
        vm.stopPrank();
        MarketState memory otherBefore = other.marketState();
        oracle.setPrice(PRICE_1000);
        loanToken.mint(LIQUIDATOR, 7_000e6);

        // when
        vm.prank(LIQUIDATOR);
        market.liquidate(BORROWER, 5e18, 0, "");

        // then
        // 손실이 난 시장의 예치자만 손실 분담
        assertLt(market.totalAssets(), 10_000e6);
        assertEq(abi.encode(other.marketState()), abi.encode(otherBefore));
        assertEq(other.previewRedeem(otherShares), 10_000e6);
        assertTrue(other.isHealthy(RECEIVER));
    }
}
