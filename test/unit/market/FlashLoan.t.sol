// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IMarket, MarketState} from "../../../src/interfaces/IMarket.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {FlashBorrower} from "../../mocks/FlashBorrower.sol";
import {BaseTest} from "../../BaseTest.sol";

contract FlashLoanTest is BaseTest {
    FlashBorrower internal borrower;

    function setUp() public override {
        super.setUp();
        // 예치 10,000, 담보 5 WETH, 차입 7,000, 시장 잔액 3,000
        _setUpExample();
        borrower = new FlashBorrower(market);
    }

    function test_FlashLoan_LoanTokenReturnsAndLedgerUnchanged() public {
        // given
        _forward(1 days);
        bytes memory stateBefore = abi.encode(market.marketState());
        uint256 balanceBefore = loanToken.balanceOf(address(market));
        assertEq(balanceBefore, 3_000e6);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.FlashLoan(address(borrower), address(loanToken), 3_000e6);
        borrower.flashLoan(address(loanToken), 3_000e6, hex"1234");

        // then
        // 콜백 안에서 빌린 돈 보유
        assertEq(borrower.tokenInCallback(), address(loanToken));
        assertEq(borrower.assetsInCallback(), 3_000e6);
        assertEq(borrower.balanceInCallback(), 3_000e6);
        assertEq(borrower.dataInCallback(), hex"1234");
        // 잔액 복원, 장부 유지
        assertEq(loanToken.balanceOf(address(market)), balanceBefore);
        assertEq(loanToken.balanceOf(address(borrower)), 0);
        assertEq(abi.encode(market.marketState()), stateBefore);
    }

    function test_FlashLoan_CollateralToken() public {
        // when
        borrower.flashLoan(address(collateralToken), 5e18, "");

        // then
        assertEq(borrower.balanceInCallback(), 5e18);
        assertEq(collateralToken.balanceOf(address(market)), 5e18);
        assertEq(market.position(BORROWER).collateral, 5e18);
    }

    function test_FlashLoan_RevertWhen_ZeroAssets() public {
        // when, then
        vm.expectRevert(IMarket.ZeroAssets.selector);
        borrower.flashLoan(address(loanToken), 0, "");
    }

    function test_FlashLoan_RevertWhen_UnsupportedToken() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarket.UnsupportedToken.selector, address(this)));
        borrower.flashLoan(address(this), 1, "");
    }

    function test_FlashLoan_RevertWhen_MoreThanBalance() public {
        // when, then
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(market), 3_000e6, 3_000e6 + 1
            )
        );
        borrower.flashLoan(address(loanToken), 3_000e6 + 1, "");
    }

    function test_FlashLoan_RevertWhen_NotRepaid() public {
        // given
        borrower.setMode(FlashBorrower.Mode.NoRepay);

        // when, then
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(market), 0, 1_000e6)
        );
        borrower.flashLoan(address(loanToken), 1_000e6, "");

        // then
        assertEq(loanToken.balanceOf(address(market)), 3_000e6);
    }

    function test_FlashLoan_RevertWhen_CallerHasNoCallback() public {
        // when, then
        vm.prank(OTHER);
        vm.expectRevert();
        market.flashLoan(address(loanToken), 1_000e6, "");
    }

    function testFuzz_FlashLoan_BalanceAndLedgerUnchanged(uint256 assets, bool isCollateral) public {
        // given
        address token = isCollateral ? address(collateralToken) : address(loanToken);
        uint256 balanceBefore = isCollateral ? 5e18 : 3_000e6;
        assets = bound(assets, 1, balanceBefore);
        MarketState memory stateBefore = market.marketState();

        // when
        borrower.flashLoan(token, assets, "");

        // then
        assertEq(
            isCollateral ? collateralToken.balanceOf(address(market)) : loanToken.balanceOf(address(market)),
            balanceBefore
        );
        assertEq(abi.encode(market.marketState()), abi.encode(stateBefore));
    }
}
