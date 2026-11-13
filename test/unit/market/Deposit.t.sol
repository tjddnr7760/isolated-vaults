// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IMarket} from "../../../src/interfaces/IMarket.sol";
import {BaseTest} from "../../BaseTest.sol";

contract DepositTest is BaseTest {
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /* deposit */

    function test_Deposit_FirstDepositMintsVirtualSharesRate() public {
        // when
        uint256 shares = _deposit(SUPPLIER, 10_000e6);

        // then
        // 10,000e6 × (0 + 1e6) ÷ (0 + 1)
        assertEq(shares, 10_000e6 * VIRTUAL_SHARES);
        assertEq(market.balanceOf(SUPPLIER), shares);
        assertEq(market.totalSupply(), shares);
        assertEq(market.marketState().totalSupplyAssets, 10_000e6);
        assertEq(market.totalAssets(), 10_000e6);
        assertEq(loanToken.balanceOf(address(market)), 10_000e6);
    }

    function test_Deposit_ToReceiver() public {
        // given
        loanToken.mint(SUPPLIER, 100e6);

        // when
        vm.prank(SUPPLIER);
        uint256 shares = market.deposit(100e6, RECEIVER);

        // then
        assertEq(market.balanceOf(RECEIVER), shares);
        assertEq(market.balanceOf(SUPPLIER), 0);
        assertEq(loanToken.balanceOf(SUPPLIER), 0);
    }

    function test_Deposit_RevertWhen_ZeroShares() public {
        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert(IMarket.ZeroShares.selector);
        market.deposit(0, SUPPLIER);
    }

    function test_Deposit_RevertWhen_ReceiverZero() public {
        // given
        loanToken.mint(SUPPLIER, 100e6);

        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        market.deposit(100e6, address(0));
    }

    function test_Deposit_AccruesInterestFirst() public {
        // given
        _setUpExample();
        _forward(30 days);
        uint256 expectedTotalAssets = market.totalAssets();

        // when
        _deposit(OTHER, 1_000e6);

        // then
        // 예치 전 이자 반영
        assertEq(market.marketState().lastUpdate, block.timestamp);
        assertEq(market.marketState().totalSupplyAssets, expectedTotalAssets + 1_000e6);
    }

    /// @dev 이자가 쌓인 상태에서도 미리보기와 실행 일치
    function testFuzz_Deposit_PreviewMatchesExecution(uint256 assets, uint256 elapsed) public {
        // given
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        elapsed = bound(elapsed, 0, 365 days);
        _setUpExample();
        _forward(elapsed);
        uint256 previewed = market.previewDeposit(assets);

        // when
        uint256 shares = _deposit(OTHER, assets);

        // then
        assertEq(shares, previewed);
    }

    /// @dev 넣었다 바로 빼도 이득 없음
    function testFuzz_Deposit_RoundTripNeverProfits(uint256 assets, uint256 elapsed) public {
        // given
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        elapsed = bound(elapsed, 0, 365 days);
        _setUpExample();
        _forward(elapsed);
        // 꺼낼 현금 확보
        _deposit(SUPPLIER, assets);
        uint256 shares = _deposit(OTHER, assets);

        // when
        vm.prank(OTHER);
        uint256 redeemed = market.redeem(shares, OTHER, OTHER);

        // then
        assertLe(redeemed, assets);
    }

    /* mint */

    function test_Mint_PullsAssetsRoundedUp() public {
        // given
        _setUpExample();
        _forward(30 days);
        uint256 shares = 1e12 + 1;
        uint256 expectedAssets = market.previewMint(shares);
        loanToken.mint(OTHER, expectedAssets);

        // when
        vm.prank(OTHER);
        uint256 assets = market.mint(shares, OTHER);

        // then
        assertEq(assets, expectedAssets);
        assertEq(market.balanceOf(OTHER), shares);
        assertEq(loanToken.balanceOf(OTHER), 0);
        // 낸 자산의 가치가 받은 지분의 가치 이상
        assertGe(assets, market.convertToAssets(shares));
    }

    function test_Mint_RevertWhen_ZeroShares() public {
        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert(IMarket.ZeroShares.selector);
        market.mint(0, SUPPLIER);
    }

    /* max */

    function test_MaxDepositAndMint_AreUnlimited() public view {
        // when, then
        assertEq(market.maxDeposit(SUPPLIER), type(uint256).max);
        assertEq(market.maxMint(SUPPLIER), type(uint256).max);
    }
}
