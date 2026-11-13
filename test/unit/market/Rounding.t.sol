// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

import {MarketState} from "../../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {BaseTest} from "../../BaseTest.sol";

/// @dev 올림과 내림의 답이 다르도록 이자가 붙은 장부와 나누어떨어지지 않는 가격 사용
contract RoundingTest is BaseTest {
    using MathLib for uint256;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    // 1e36 으로 나누어떨어지지 않는 가격
    uint256 internal constant PRICE = PRICE_1600 + 12_345;

    uint256 internal lif;

    function setUp() public override {
        super.setUp();
        // 예치 10,000, 담보 5 WETH, 차입 7,000, 30일 이자 반영
        _setUpExample();
        loanToken.mint(BORROWER, 100_000e6);
        loanToken.mint(LIQUIDATOR, 100_000e6);
        vm.prank(BORROWER);
        loanToken.approve(address(market), type(uint256).max);
        vm.prank(LIQUIDATOR);
        loanToken.approve(address(market), type(uint256).max);
        _forward(30 days);
        market.accrueInterest();
        lif = market.liquidationIncentiveFactor();
    }

    /* 기대값 계산 */

    function _toSharesUp(uint256 assets, MarketState memory s) internal pure returns (uint256) {
        return assets.mulDivUp(s.totalBorrowShares + VIRTUAL_SHARES, s.totalBorrowAssets + VIRTUAL_ASSETS);
    }

    function _toSharesDown(uint256 assets, MarketState memory s) internal pure returns (uint256) {
        return assets.mulDivDown(s.totalBorrowShares + VIRTUAL_SHARES, s.totalBorrowAssets + VIRTUAL_ASSETS);
    }

    function _toAssetsUp(uint256 shares, MarketState memory s) internal pure returns (uint256) {
        return shares.mulDivUp(s.totalBorrowAssets + VIRTUAL_ASSETS, s.totalBorrowShares + VIRTUAL_SHARES);
    }

    function _toAssetsDown(uint256 shares, MarketState memory s) internal pure returns (uint256) {
        return shares.mulDivDown(s.totalBorrowAssets + VIRTUAL_ASSETS, s.totalBorrowShares + VIRTUAL_SHARES);
    }

    /* 대출과 상환 */

    /// @dev 대출 때 생기는 차입 지분은 올림
    function test_Borrow_SharesRoundUp() public {
        // given
        MarketState memory s = market.marketState();
        uint256 assets = 500e6 + 3;
        uint256 expected = _toSharesUp(assets, s);
        assertEq(expected, _toSharesDown(assets, s) + 1);
        uint256 sharesBefore = market.position(BORROWER).borrowShares;

        // when
        vm.prank(BORROWER);
        uint256 shares = market.borrow(assets, BORROWER, BORROWER);

        // then
        assertEq(shares, expected);
        assertEq(market.position(BORROWER).borrowShares, sharesBefore + expected);
        assertEq(market.marketState().totalBorrowShares, s.totalBorrowShares + expected);
    }

    /// @dev 금액으로 갚을 때 지워지는 차입 지분은 내림
    function test_Repay_SharesRoundDown() public {
        // given
        MarketState memory s = market.marketState();
        uint256 assets = 1_000e6 + 3;
        uint256 expected = _toSharesDown(assets, s);
        assertEq(expected + 1, _toSharesUp(assets, s));
        uint256 sharesBefore = market.position(BORROWER).borrowShares;

        // when
        vm.prank(BORROWER);
        (uint256 repaidAssets, uint256 repaidShares) = market.repay(assets, 0, BORROWER);

        // then
        assertEq(repaidAssets, assets);
        assertEq(repaidShares, expected);
        assertEq(market.position(BORROWER).borrowShares, sharesBefore - expected);
    }

    /// @dev 지분으로 갚을 때 내는 금액은 올림
    function test_Repay_AssetsRoundUp() public {
        // given
        MarketState memory s = market.marketState();
        uint256 shares = 1_000e6 * 1e6 + 123_457;
        uint256 expected = _toAssetsUp(shares, s);
        assertEq(expected, _toAssetsDown(shares, s) + 1);
        uint256 balanceBefore = loanToken.balanceOf(BORROWER);

        // when
        vm.prank(BORROWER);
        (uint256 repaidAssets,) = market.repay(0, shares, BORROWER);

        // then
        assertEq(repaidAssets, expected);
        assertEq(balanceBefore - loanToken.balanceOf(BORROWER), expected);
        assertEq(market.marketState().totalBorrowAssets, s.totalBorrowAssets - expected);
    }

    /* 청산 */

    /// @dev 담보량 지정 청산은 갚는 쪽 계산이 모두 올림
    function test_Liquidate_SeizedPathRoundsAgainstLiquidator() public {
        // given
        oracle.setPrice(PRICE);
        MarketState memory s = market.marketState();
        uint256 seized = 1e18 + 1e9 + 1;

        // 가져갈 담보의 가치, 올림
        uint256 quoted = Math.mulDiv(seized, PRICE, ConstantsLib.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
        uint256 quotedDown = Math.mulDiv(seized, PRICE, ConstantsLib.ORACLE_PRICE_SCALE);
        assertEq(quoted, quotedDown + 1);
        // 갚을 지분, 올림
        uint256 expectedShares = _toSharesUp(quoted.wDivUp(lif), s);
        assertEq(expectedShares, _toSharesDown(quoted.wDivUp(lif), s) + 1);
        assertGt(expectedShares, _toSharesUp(quotedDown.wDivUp(lif), s));
        assertGt(expectedShares, _toSharesUp(quoted.wDivDown(lif), s));
        // 내는 돈, 올림
        uint256 expectedRepaid = _toAssetsUp(expectedShares, s);
        assertEq(expectedRepaid, _toAssetsDown(expectedShares, s) + 1);
        uint256 sharesBefore = market.position(BORROWER).borrowShares;
        uint256 balanceBefore = loanToken.balanceOf(LIQUIDATOR);

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seizedReturned, uint256 repaid) = market.liquidate(BORROWER, seized, 0, "");

        // then
        assertEq(seizedReturned, seized);
        assertEq(repaid, expectedRepaid);
        assertEq(balanceBefore - loanToken.balanceOf(LIQUIDATOR), expectedRepaid);
        assertEq(sharesBefore - market.position(BORROWER).borrowShares, expectedShares);
        assertEq(market.marketState().totalBorrowAssets, s.totalBorrowAssets - expectedRepaid);
    }

    /// @dev 지분 지정 청산은 담보 계산이 내림, 내는 돈이 올림
    function test_Liquidate_SharesPathRoundsAgainstLiquidator() public {
        // given
        oracle.setPrice(PRICE);
        MarketState memory s = market.marketState();
        uint256 repaidShares = 3_000e6 * 1e6 + 123_457;

        // 담보 계산용 자산, 내림
        uint256 assetsDown = _toAssetsDown(repaidShares, s);
        assertEq(assetsDown + 1, _toAssetsUp(repaidShares, s));
        // 가져갈 담보, 내림
        uint256 expectedSeized = Math.mulDiv(assetsDown.wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE);
        assertEq(
            expectedSeized + 1,
            Math.mulDiv(assetsDown.wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE, Math.Rounding.Ceil)
        );
        assertLt(expectedSeized, Math.mulDiv((assetsDown + 1).wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, PRICE));
        assertLt(expectedSeized, Math.mulDiv(assetsDown.mulDivUp(lif, 1e18), ConstantsLib.ORACLE_PRICE_SCALE, PRICE));
        // 내는 돈, 올림
        uint256 expectedRepaid = _toAssetsUp(repaidShares, s);
        uint256 collateralBefore = market.position(BORROWER).collateral;

        // when
        vm.prank(LIQUIDATOR);
        (uint256 seized, uint256 repaid) = market.liquidate(BORROWER, 0, repaidShares, "");

        // then
        assertEq(seized, expectedSeized);
        assertEq(repaid, expectedRepaid);
        assertEq(collateralToken.balanceOf(LIQUIDATOR), expectedSeized);
        assertEq(collateralBefore - market.position(BORROWER).collateral, expectedSeized);
    }

    /* 예치 */

    /// @dev 현금으로 살 수 있는 지분의 내림값, OpenZeppelin ERC4626 의 환산식
    function _maxRedeemBoundByLiquidity() internal view returns (uint256 liquidity, uint256 expected) {
        liquidity = market.liquidity();
        expected = Math.mulDiv(liquidity, market.totalSupply() + 1e6, market.totalAssets() + 1);
        assertEq(
            expected + 1,
            Math.mulDiv(liquidity, market.totalSupply() + 1e6, market.totalAssets() + 1, Math.Rounding.Ceil)
        );
        assertLt(expected, market.balanceOf(SUPPLIER));
    }

    /// @dev maxRedeem 은 현금으로 살 수 있는 지분의 내림
    function test_MaxRedeem_RoundsDownWhenBoundByLiquidity() public view {
        // given
        (, uint256 expected) = _maxRedeemBoundByLiquidity();

        // when, then
        assertEq(market.maxRedeem(SUPPLIER), expected);
    }

    /// @dev maxRedeem 만큼 꺼낸 자산은 현금 이하
    function test_Redeem_MaxRedeemStaysWithinLiquidity() public {
        // given
        (uint256 liquidity, uint256 expected) = _maxRedeemBoundByLiquidity();

        // when
        vm.prank(SUPPLIER);
        uint256 assets = market.redeem(expected, SUPPLIER, SUPPLIER);

        // then
        assertLe(assets, liquidity);
    }
}
