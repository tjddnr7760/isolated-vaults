// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestUSDC} from "../../../script/testnet/TestUSDC.sol";

contract TestUSDCTest is Test {
    address internal DEPLOYER = makeAddr("deployer");
    address internal USER = makeAddr("user");

    TestUSDC internal token;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new TestUSDC(DEPLOYER, 1_000_000e6);
    }

    function test_Constructor_MintsInitialAmountWithSixDecimals() public view {
        // when, then
        assertEq(token.decimals(), 6);
        assertEq(token.symbol(), "tUSDC");
        assertEq(token.balanceOf(DEPLOYER), 1_000_000e6);
        assertEq(token.totalSupply(), 1_000_000e6);
    }

    function test_Faucet_GivesFixedAmount() public {
        // when
        vm.prank(USER);
        token.faucet();

        // then
        assertEq(token.balanceOf(USER), token.FAUCET_AMOUNT());
        assertEq(token.lastFaucetAt(USER), block.timestamp);
    }

    function test_Faucet_RevertWhen_UsedAgainWithinCooldown() public {
        // given
        vm.prank(USER);
        token.faucet();
        uint256 availableAt = block.timestamp + token.FAUCET_COOLDOWN();
        skip(token.FAUCET_COOLDOWN() - 1);

        // when, then
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.FaucetCooldown.selector, availableAt));
        token.faucet();
    }

    function test_Faucet_WorksAgainAfterCooldown() public {
        // given
        vm.prank(USER);
        token.faucet();
        skip(token.FAUCET_COOLDOWN());

        // when
        vm.prank(USER);
        token.faucet();

        // then
        assertEq(token.balanceOf(USER), 2 * token.FAUCET_AMOUNT());
    }

    /// @dev 대기 시간은 주소마다 따로
    function test_Faucet_CooldownIsPerAddress() public {
        // given
        vm.prank(USER);
        token.faucet();

        // when
        vm.prank(DEPLOYER);
        token.faucet();

        // then
        assertEq(token.balanceOf(DEPLOYER), 1_000_000e6 + token.FAUCET_AMOUNT());
    }
}
