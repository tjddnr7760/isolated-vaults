// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {OracleAdapter} from "../../../src/OracleAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAggregator, MockAggregatorWithBounds} from "../../mocks/MockAggregator.sol";

contract OracleAdapterTest is Test {
    uint256 internal constant MAX_STALENESS = 4500;
    int256 internal constant FALLBACK_MIN = 10e8;
    int256 internal constant FALLBACK_MAX = 1_000_000e8;
    int256 internal constant ANSWER_2000 = 2000e8;

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockAggregator internal feed;
    OracleAdapter internal adapter;

    function setUp() public {
        vm.warp(1_700_000_000);

        loanToken = new MockERC20("USD Coin", "USDC", 6);
        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        feed = new MockAggregator(8);
        feed.setRoundData(ANSWER_2000, block.timestamp);
        adapter = _deploy(address(feed));
    }

    function _deploy(address feed_) internal returns (OracleAdapter) {
        return new OracleAdapter(
            feed_, address(loanToken), address(collateralToken), MAX_STALENESS, FALLBACK_MIN, FALLBACK_MAX
        );
    }

    /* 생성자 */

    function test_Constructor_SetsImmutables() public view {
        // when, then
        assertEq(adapter.LOAN_TOKEN(), address(loanToken));
        assertEq(adapter.COLLATERAL_TOKEN(), address(collateralToken));
        assertEq(address(adapter.FEED()), address(feed));
        assertEq(adapter.MAX_STALENESS(), MAX_STALENESS);
        // 36 + 6 − 18 − 8 = 16
        assertEq(adapter.SCALE_FACTOR(), 1e16);
    }

    function test_Constructor_UsesFallbackBoundsWhenAggregatorHasNone() public view {
        // when, then
        assertEq(adapter.MIN_ANSWER(), FALLBACK_MIN);
        assertEq(adapter.MAX_ANSWER(), FALLBACK_MAX);
    }

    function test_Constructor_ReadsAggregatorBounds() public {
        // given
        MockAggregatorWithBounds bounded = new MockAggregatorWithBounds(8, 100e8, 50_000e8);

        // when
        OracleAdapter boundedAdapter = _deploy(address(bounded));

        // then
        assertEq(boundedAdapter.MIN_ANSWER(), 100e8);
        assertEq(boundedAdapter.MAX_ANSWER(), 50_000e8);
    }

    function test_Constructor_UsesFallbackWhenAggregatorBoundsDisabled() public {
        // given
        MockAggregatorWithBounds disabled = new MockAggregatorWithBounds(8, 0, 0);

        // when
        OracleAdapter disabledAdapter = _deploy(address(disabled));

        // then
        assertEq(disabledAdapter.MIN_ANSWER(), FALLBACK_MIN);
        assertEq(disabledAdapter.MAX_ANSWER(), FALLBACK_MAX);
    }

    function test_Constructor_RevertWhen_FeedZero() public {
        // when, then
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(0), address(loanToken), address(collateralToken), MAX_STALENESS, 1, 2);
    }

    function test_Constructor_RevertWhen_LoanTokenZero() public {
        // when, then
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(feed), address(0), address(collateralToken), MAX_STALENESS, 1, 2);
    }

    function test_Constructor_RevertWhen_CollateralTokenZero() public {
        // when, then
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(address(feed), address(loanToken), address(0), MAX_STALENESS, 1, 2);
    }

    function test_Constructor_RevertWhen_ZeroStaleness() public {
        // when, then
        vm.expectRevert(OracleAdapter.ZeroStaleness.selector);
        new OracleAdapter(address(feed), address(loanToken), address(collateralToken), 0, FALLBACK_MIN, FALLBACK_MAX);
    }

    function test_Constructor_RevertWhen_MinEqualsMax() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidBounds.selector, int256(5), int256(5)));
        new OracleAdapter(address(feed), address(loanToken), address(collateralToken), MAX_STALENESS, 5, 5);
    }

    function test_Constructor_RevertWhen_MinNegative() public {
        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidBounds.selector, int256(-1), int256(5)));
        new OracleAdapter(address(feed), address(loanToken), address(collateralToken), MAX_STALENESS, -1, 5);
    }

    function test_Constructor_RevertWhen_UnsupportedDecimals() public {
        // given
        // 36 + 0 − 30 − 8 < 0
        MockERC20 zeroDecimals = new MockERC20("Zero", "ZERO", 0);
        MockERC20 thirtyDecimals = new MockERC20("Thirty", "THIRTY", 30);

        // when, then
        vm.expectRevert(OracleAdapter.UnsupportedDecimals.selector);
        new OracleAdapter(
            address(feed), address(zeroDecimals), address(thirtyDecimals), MAX_STALENESS, FALLBACK_MIN, FALLBACK_MAX
        );
    }

    /* price */

    function test_Price_ScalesTo1e36() public view {
        // when
        // 1 WETH = 2,000 USDC 이면 5 WETH = 10,000 USDC
        uint256 price = adapter.price();

        // then
        assertEq(price, 2000e6 * 1e36 / 1e18);
        assertEq(5e18 * price / 1e36, 10_000e6);
    }

    function testFuzz_Price_ScalesAnyDecimals(uint8 loanDecimals, uint8 collateralDecimals, uint8 feedDecimals) public {
        // given
        loanDecimals = uint8(bound(loanDecimals, 0, 18));
        collateralDecimals = uint8(bound(collateralDecimals, 0, 18));
        feedDecimals = uint8(bound(feedDecimals, 0, 18));

        MockERC20 loan = new MockERC20("Loan", "LOAN", loanDecimals);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", collateralDecimals);
        MockAggregator anyFeed = new MockAggregator(feedDecimals);
        // 담보 1 개 = 대출 자산 2,000 개
        anyFeed.setRoundData(int256(2000 * 10 ** uint256(feedDecimals)), block.timestamp);

        OracleAdapter anyAdapter =
            new OracleAdapter(address(anyFeed), address(loan), address(collateral), MAX_STALENESS, 0, type(int256).max);

        // when, then
        // 담보 1 개의 값이 대출 자산 2,000 개인지 확인
        assertEq(10 ** uint256(collateralDecimals) * anyAdapter.price() / 1e36, 2000 * 10 ** uint256(loanDecimals));
    }

    function test_Price_RevertWhen_AnswerZero() public {
        // given
        feed.setRoundData(0, block.timestamp);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NonPositivePrice.selector, int256(0)));
        adapter.price();
    }

    function test_Price_RevertWhen_AnswerNegative() public {
        // given
        feed.setRoundData(-1, block.timestamp);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NonPositivePrice.selector, int256(-1)));
        adapter.price();
    }

    /// @dev 바닥과 같은 답도 거절
    function test_Price_RevertWhen_AnswerAtMin() public {
        // given
        feed.setRoundData(FALLBACK_MIN, block.timestamp);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceOutOfBounds.selector, FALLBACK_MIN));
        adapter.price();
    }

    function test_Price_AcceptsAnswerJustAboveMin() public {
        // given
        feed.setRoundData(FALLBACK_MIN + 1, block.timestamp);

        // when
        uint256 price = adapter.price();

        // then
        assertEq(price, uint256(FALLBACK_MIN + 1) * adapter.SCALE_FACTOR());
    }

    /// @dev 천장과 같은 답도 거절
    function test_Price_RevertWhen_AnswerAtMax() public {
        // given
        feed.setRoundData(FALLBACK_MAX, block.timestamp);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceOutOfBounds.selector, FALLBACK_MAX));
        adapter.price();
    }

    function test_Price_AcceptsAnswerJustBelowMax() public {
        // given
        feed.setRoundData(FALLBACK_MAX - 1, block.timestamp);

        // when
        uint256 price = adapter.price();

        // then
        assertEq(price, uint256(FALLBACK_MAX - 1) * adapter.SCALE_FACTOR());
    }

    /// @dev 허용 시간 딱 맞으면 통과
    function test_Price_AcceptsAtMaxStaleness() public {
        // given
        uint256 updatedAt = block.timestamp;
        vm.warp(updatedAt + MAX_STALENESS);

        // when
        uint256 price = adapter.price();

        // then
        assertEq(price, 2000e6 * 1e36 / 1e18);
    }

    /// @dev 허용 시간을 1 초 넘으면 실패
    function test_Price_RevertWhen_Stale() public {
        // given
        uint256 updatedAt = block.timestamp;
        vm.warp(updatedAt + MAX_STALENESS + 1);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, updatedAt));
        adapter.price();
    }

    function test_Price_RevertWhen_UpdatedAtUnset() public {
        // given
        feed.setRoundData(ANSWER_2000, 0);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, uint256(0)));
        adapter.price();
    }

    function test_Price_RevertWhen_UpdatedAtInFuture() public {
        // given
        feed.setRoundData(ANSWER_2000, block.timestamp + 1);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, block.timestamp + 1));
        adapter.price();
    }

    function test_Price_RevertWhen_UpdatedAtZero() public {
        // given
        vm.warp(MAX_STALENESS);
        feed.setRoundData(FALLBACK_MIN + 1, 0);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, uint256(0)));
        adapter.price();
    }
}
