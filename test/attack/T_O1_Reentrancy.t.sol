// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Market} from "../../src/Market.sol";
import {MarketParams} from "../../src/interfaces/IMarket.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";
import {BaseTest} from "../BaseTest.sol";
import {HookToken} from "./attackers/HookToken.sol";
import {ReentrantAttacker} from "./attackers/ReentrantAttacker.sol";

/// @notice 훅 있는 토큰으로 재진입 공격
contract ReentrancyAttackTest is BaseTest {
    uint256 internal constant STATE_CHANGING_FUNCTIONS = 12;

    HookToken internal hookToken;
    Market internal hookMarket;
    ReentrantAttacker internal attacker;

    function setUp() public override {
        super.setUp();

        hookToken = new HookToken();
        MockOracleAdapter hookOracle = new MockOracleAdapter(address(hookToken), address(collateralToken));
        hookOracle.setPrice(PRICE_2000);
        MarketParams memory p = params;
        p.loanToken = address(hookToken);
        p.oracle = address(hookOracle);
        hookMarket = _deployMarket(p);

        attacker = new ReentrantAttacker(hookMarket);
        hookToken.setHookTarget(address(attacker));

        // 다른 예치자의 10,000 과 공격자의 밑천
        hookToken.mint(SUPPLIER, 10_000e6);
        vm.prank(SUPPLIER);
        hookMarket.deposit(10_000e6, SUPPLIER);
        hookToken.mint(address(attacker), 1_000e6);
        collateralToken.mint(address(attacker), 5e18);
    }

    function _assertAllBlocked() internal view {
        assertEq(attacker.hookCalls(), 1);
        assertEq(attacker.blockedCalls(), STATE_CHANGING_FUNCTIONS);
        assertEq(attacker.lastSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Attack_ReenterDuringDeposit_Blocked() public {
        // given
        attacker.arm(true);

        // when
        attacker.deposit(1_000e6);

        // then
        _assertAllBlocked();
        // 훅에서 읽은 뷰 값과 호출 뒤 값 일치
        assertEq(attacker.totalSupplyAssetsInHook(), 11_000e6);
        assertEq(attacker.totalAssetsInHook(), hookMarket.totalAssets());
        assertEq(attacker.sharePriceInHook(), hookMarket.convertToAssets(1e24));
    }

    function test_Attack_ReenterDuringWithdraw_Blocked() public {
        // given
        attacker.deposit(1_000e6);
        attacker.arm(true);

        // when
        attacker.withdraw(500e6);

        // then
        _assertAllBlocked();
        assertEq(attacker.totalSupplyAssetsInHook(), 10_500e6);
        assertEq(attacker.totalAssetsInHook(), hookMarket.totalAssets());
        assertEq(attacker.sharePriceInHook(), hookMarket.convertToAssets(1e24));
    }

    function test_Attack_ReenterDuringBorrow_Blocked() public {
        // given
        attacker.supplyCollateral(5e18);
        attacker.arm(true);

        // when
        attacker.borrow(1_000e6);

        // then
        _assertAllBlocked();
        assertEq(hookMarket.debtOf(address(attacker)), 1_000e6);
        assertEq(hookMarket.marketState().totalBorrowAssets, 1_000e6);
        // 재진입으로 추가 대출 실패
        assertEq(hookToken.balanceOf(address(attacker)), 2_000e6);
    }
}
