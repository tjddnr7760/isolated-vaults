// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.sol";

/// @notice 첫 예치자 지분 가격 부풀리기 공격
contract DonationInflationAttackTest is BaseTest {
    address internal ATTACKER = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        vm.startPrank(ATTACKER);
        loanToken.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev 빈 시장에 1 wei 예치 뒤 10,000 USDC 직접 전송
    function _seedAndDonate() internal returns (uint256 attackerShares) {
        loanToken.mint(ATTACKER, 10_000e6 + 1);
        vm.prank(ATTACKER);
        attackerShares = market.deposit(1, ATTACKER);
        vm.prank(ATTACKER);
        loanToken.transfer(address(market), 10_000e6);
    }

    /// @dev 직접 전송 뒤 지분 가격 유지
    function test_Attack_DonationInflationSharePrice_Blocked() public {
        // given
        loanToken.mint(ATTACKER, 10_000e6 + 1);
        vm.prank(ATTACKER);
        uint256 attackerShares = market.deposit(1, ATTACKER);

        // when
        vm.prank(ATTACKER);
        loanToken.transfer(address(market), 10_000e6);

        // then
        assertEq(market.totalAssets(), 1);
        assertEq(market.convertToAssets(attackerShares), 1);
    }

    /// @dev 직접 전송 뒤 피해자의 정상 비율 지분 수령
    function test_Attack_DonationInflationVictimDeposit_Blocked() public {
        // given
        _seedAndDonate();

        // when
        uint256 victimShares = _deposit(SUPPLIER, 10_000e6);

        // then
        assertEq(victimShares, 10_000e6 * 1e6);
    }

    /// @dev 피해자의 전액 회수
    function test_Attack_DonationInflationVictimRedeem_Blocked() public {
        // given
        _seedAndDonate();
        uint256 victimShares = _deposit(SUPPLIER, 10_000e6);

        // when
        vm.prank(SUPPLIER);
        uint256 redeemed = market.redeem(victimShares, SUPPLIER, SUPPLIER);

        // then
        assertEq(redeemed, 10_000e6);
    }

    /// @dev 공격자의 1 wei 회수
    function test_Attack_DonationInflationAttackerRedeem_Blocked() public {
        // given
        uint256 attackerShares = _seedAndDonate();
        uint256 victimShares = _deposit(SUPPLIER, 10_000e6);
        vm.prank(SUPPLIER);
        market.redeem(victimShares, SUPPLIER, SUPPLIER);

        // when
        vm.prank(ATTACKER);
        uint256 redeemed = market.redeem(attackerShares, ATTACKER, ATTACKER);

        // then
        assertEq(redeemed, 1);
        assertEq(loanToken.balanceOf(ATTACKER), 1);
    }

    /// @dev 얼마를 보내도 다음 예치자 손실은 1 wei 이하
    function testFuzz_Attack_DonationInflation_VictimNeverLoses(uint256 seed, uint256 donation, uint256 victimAssets)
        public
    {
        // given
        seed = bound(seed, 1, 1e6);
        donation = bound(donation, 1, MAX_TEST_ASSETS);
        victimAssets = bound(victimAssets, 1, MAX_TEST_ASSETS);
        loanToken.mint(ATTACKER, seed + donation);
        vm.startPrank(ATTACKER);
        market.deposit(seed, ATTACKER);
        loanToken.transfer(address(market), donation);
        vm.stopPrank();

        uint256 victimShares = _deposit(SUPPLIER, victimAssets);

        // when
        vm.prank(SUPPLIER);
        uint256 redeemed = market.redeem(victimShares, SUPPLIER, SUPPLIER);

        // then
        assertEq(redeemed, victimAssets);
    }
}
