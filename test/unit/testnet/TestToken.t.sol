// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestToken} from "../../../script/testnet/TestToken.sol";

contract TestTokenTest is Test {
    address internal USER = makeAddr("user");

    TestToken internal token;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new TestToken("Test Wrapped Bitcoin", "tWBTC", 8, 0.15e8);
    }

    function test_Constructor_SetsMetadataAndNoSupply() public view {
        // when, then
        assertEq(token.name(), "Test Wrapped Bitcoin");
        assertEq(token.symbol(), "tWBTC");
        assertEq(token.decimals(), 8);
        assertEq(token.FAUCET_AMOUNT(), 0.15e8);
        assertEq(token.totalSupply(), 0);
    }

    function test_Faucet_GivesFixedAmount() public {
        // when
        vm.prank(USER);
        token.faucet();

        // then
        assertEq(token.balanceOf(USER), 0.15e8);
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
        vm.expectRevert(abi.encodeWithSelector(TestToken.FaucetCooldown.selector, availableAt));
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
        assertEq(token.balanceOf(USER), 2 * 0.15e8);
    }
}
