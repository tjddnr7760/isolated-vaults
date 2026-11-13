// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FlashBorrower} from "../mocks/FlashBorrower.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 플래시론 콜백 안 재진입 공격
contract FlashLoanReentryAttackTest is BaseTest {
    FlashBorrower internal attacker;

    function setUp() public override {
        super.setUp();
        _deposit(SUPPLIER, 10_000e6);
        attacker = new FlashBorrower(market);
        attacker.setMode(FlashBorrower.Mode.Reenter);
    }

    function test_Attack_DepositFlashLoanedAssets_Blocked() public {
        // when
        attacker.flashLoan(address(loanToken), 10_000e6, "");

        // then
        // 콜백 안 호출 4개 모두 차단
        assertEq(attacker.blockedCalls(), 4);
        assertEq(attacker.lastSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        // 공격자의 지분, 담보, 토큰 없음
        assertEq(market.balanceOf(address(attacker)), 0);
        assertEq(market.position(address(attacker)).collateral, 0);
        assertEq(loanToken.balanceOf(address(attacker)), 0);
        // 예치자 몫과 시장 잔액 유지
        assertEq(market.totalAssets(), 10_000e6);
        assertEq(market.maxWithdraw(SUPPLIER), 10_000e6);
        assertEq(loanToken.balanceOf(address(market)), 10_000e6);
    }
}
