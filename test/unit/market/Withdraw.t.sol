// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IMarket} from "../../../src/interfaces/IMarket.sol";
import {BaseTest} from "../../BaseTest.sol";

contract WithdrawTest is BaseTest {
    /* withdraw */

    function test_Withdraw_BurnsSharesAndSendsAssets() public {
        // given
        uint256 shares = _deposit(SUPPLIER, 10_000e6);

        // when
        vm.prank(SUPPLIER);
        uint256 burned = market.withdraw(4_000e6, RECEIVER, SUPPLIER);

        // then
        assertEq(burned, 4_000e6 * 1e6);
        assertEq(market.balanceOf(SUPPLIER), shares - burned);
        assertEq(loanToken.balanceOf(RECEIVER), 4_000e6);
        assertEq(market.marketState().totalSupplyAssets, 6_000e6);
    }

    function test_Withdraw_BySpenderWithAllowance() public {
        // given
        uint256 shares = _deposit(SUPPLIER, 1_000e6);
        vm.prank(SUPPLIER);
        market.approve(OTHER, shares);

        // when
        vm.prank(OTHER);
        market.withdraw(1_000e6, OTHER, SUPPLIER);

        // then
        assertEq(loanToken.balanceOf(OTHER), 1_000e6);
        assertEq(market.allowance(SUPPLIER, OTHER), 0);
    }

    function test_Withdraw_RevertWhen_SpenderHasNoAllowance() public {
        // given
        _deposit(SUPPLIER, 1_000e6);

        // when, then
        vm.prank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 0, 1_000e6 * 1e6)
        );
        market.withdraw(1_000e6, OTHER, SUPPLIER);
    }

    function test_Withdraw_RevertWhen_ExceedsLiquidity() public {
        // given
        _setUpExample();
        // 현금 3,000, 지분 가치는 10,000 이지만 3,000 까지만 인출 가능
        assertEq(market.liquidity(), 3_000e6);

        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, SUPPLIER, 3_000e6 + 1, 3_000e6)
        );
        market.withdraw(3_000e6 + 1, SUPPLIER, SUPPLIER);
    }

    function test_Withdraw_RevertWhen_ReceiverZero() public {
        // given
        _deposit(SUPPLIER, 1_000e6);

        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.withdraw(1_000e6, address(0), SUPPLIER);
    }

    /* redeem */

    function test_Redeem_AllSharesReturnsAllAssets() public {
        // given
        uint256 shares = _deposit(SUPPLIER, 10_000e6);

        // when
        vm.prank(SUPPLIER);
        uint256 assets = market.redeem(shares, SUPPLIER, SUPPLIER);

        // then
        assertEq(assets, 10_000e6);
        assertEq(market.totalSupply(), 0);
        assertEq(market.marketState().totalSupplyAssets, 0);
    }

    function test_Redeem_IncludesAccruedInterest() public {
        // given
        _setUpExample();
        _forward(30 days);
        // 빚을 전부 갚아 현금 확보
        uint256 borrowShares = market.position(BORROWER).borrowShares;
        loanToken.mint(BORROWER, 1_000e6);
        vm.prank(BORROWER);
        market.repay(0, borrowShares, BORROWER);

        uint256 shares = market.balanceOf(SUPPLIER);

        // when
        vm.prank(SUPPLIER);
        uint256 assets = market.redeem(shares, SUPPLIER, SUPPLIER);

        // then
        assertGt(assets, 10_000e6);
    }

    /* max */

    function test_MaxWithdraw_IsShareValueWhenLiquidityIsEnough() public {
        // given
        _deposit(SUPPLIER, 10_000e6);

        // when, then
        assertEq(market.maxWithdraw(SUPPLIER), 10_000e6);
        assertEq(market.maxRedeem(SUPPLIER), market.balanceOf(SUPPLIER));
    }

    function test_MaxWithdraw_IsLiquidityWhenBorrowed() public {
        // given
        _setUpExample();

        // when, then
        assertEq(market.maxWithdraw(SUPPLIER), 3_000e6);
        assertEq(market.maxRedeem(SUPPLIER), market.convertToShares(3_000e6));
    }

    /// @dev maxWithdraw 보다 1 많으면 실패
    function testFuzz_Withdraw_RevertWhen_AboveMaxWithdraw(uint256 borrowed, uint256 elapsed) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        elapsed = bound(elapsed, 0, 365 days);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);
        _forward(elapsed);
        uint256 maxAssets = market.maxWithdraw(SUPPLIER);

        // when, then
        vm.prank(SUPPLIER);
        vm.expectRevert();
        market.withdraw(maxAssets + 1, SUPPLIER, SUPPLIER);
    }

    /// @dev maxWithdraw 만큼은 성공
    function testFuzz_Withdraw_ExactlyMaxWithdraw(uint256 borrowed, uint256 elapsed) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        elapsed = bound(elapsed, 0, 365 days);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);
        _forward(elapsed);
        uint256 maxAssets = market.maxWithdraw(SUPPLIER);

        // when
        vm.prank(SUPPLIER);
        market.withdraw(maxAssets, SUPPLIER, SUPPLIER);

        // then
        assertEq(loanToken.balanceOf(SUPPLIER), maxAssets);
    }

    function testFuzz_MaxRedeem_AlwaysSucceeds(uint256 borrowed, uint256 elapsed) public {
        // given
        borrowed = bound(borrowed, MIN_DEBT, 8_000e6);
        elapsed = bound(elapsed, 0, 365 days);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, borrowed);
        _forward(elapsed);

        uint256 maxShares = market.maxRedeem(SUPPLIER);
        uint256 previewed = market.previewRedeem(maxShares);

        // when
        vm.prank(SUPPLIER);
        uint256 assets = market.redeem(maxShares, SUPPLIER, SUPPLIER);

        // then
        assertEq(assets, previewed);
        assertLe(assets, 10_000e6 - borrowed + 1_000e6);
    }

    /// @dev 이자로 총 차입이 총 예치를 넘은 상태
    function _setUpBorrowAboveSupply() internal {
        _deposit(SUPPLIER, 8_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 8_000e6);
        _forward(30 days);
    }

    /// @dev 총 차입이 총 예치를 넘으면 현금 0, 뷰는 revert 없음
    function test_MaxWithdraw_IsZeroWhenBorrowExceedsSupply() public {
        // given
        _setUpBorrowAboveSupply();

        // when, then
        assertGt(market.expectedMarketState().totalBorrowAssets, market.expectedMarketState().totalSupplyAssets);
        assertEq(market.liquidity(), 0);
        assertEq(market.maxWithdraw(SUPPLIER), 0);
        assertEq(market.maxRedeem(SUPPLIER), 0);
    }

    /// @dev 총 차입이 총 예치를 넘어도 0 인출은 revert 없음
    function test_Withdraw_ZeroAssetsWhenBorrowExceedsSupply() public {
        // given
        _setUpBorrowAboveSupply();

        // when
        vm.prank(SUPPLIER);
        market.withdraw(0, SUPPLIER, SUPPLIER);

        // then
        assertEq(loanToken.balanceOf(SUPPLIER), 0);
    }
}
