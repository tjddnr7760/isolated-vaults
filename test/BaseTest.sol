// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "../src/Market.sol";
import {KinkedRateModel} from "../src/KinkedRateModel.sol";
import {IMarket, MarketParams} from "../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../src/libraries/ConstantsLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracleAdapter} from "./mocks/MockOracleAdapter.sol";

/// @notice 테스트 공통 바탕
abstract contract BaseTest is Test {
    using MathLib for uint256;

    /* 테스트 상수 */

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant MIN_DEBT = 200e6;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;

    // 금리 곡선 값
    uint256 internal constant OPTIMAL_UTILIZATION = 0.9e18;
    uint256 internal constant BASE_RATE = 0;
    uint256 internal constant SLOPE_1 = uint256(0.04e18) / 365 days;
    uint256 internal constant SLOPE_2 = uint256(0.6e18) / 365 days;

    // 1 WETH = 2,000 USDC 가격
    uint256 internal constant PRICE_2000 = 2000e6 * 1e36 / 1e18;
    uint256 internal constant PRICE_1600 = 1600e6 * 1e36 / 1e18;
    uint256 internal constant PRICE_1000 = 1000e6 * 1e36 / 1e18;

    uint256 internal constant MIN_TEST_ASSETS = 1e6; // 1 USDC
    uint256 internal constant MAX_TEST_ASSETS = 1e15; // 10억 USDC
    uint256 internal constant MIN_TEST_COLLATERAL = 1e15; // 0.001 WETH
    uint256 internal constant MAX_TEST_COLLATERAL = 1e24; // 100만 WETH

    /* 행위자 */

    address internal SUPPLIER = makeAddr("supplier");
    address internal BORROWER = makeAddr("borrower");
    address internal LIQUIDATOR = makeAddr("liquidator");
    address internal RECEIVER = makeAddr("receiver");
    address internal OTHER = makeAddr("other");

    /* 배포물 */

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockOracleAdapter internal oracle;
    KinkedRateModel internal irm;
    Market internal market;
    MarketParams internal params;

    function setUp() public virtual {
        // lastUpdate 가 0 과 구분되도록 시각 이동
        vm.warp(1_700_000_000);

        loanToken = new MockERC20("USD Coin", "USDC", 6);
        collateralToken = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracleAdapter(address(loanToken), address(collateralToken));
        oracle.setPrice(PRICE_2000);
        irm = new KinkedRateModel(OPTIMAL_UTILIZATION, BASE_RATE, SLOPE_1, SLOPE_2);

        params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV,
            minDebt: MIN_DEBT,
            reserveFactor: RESERVE_FACTOR
        });
        market = _deployMarket(params);
    }

    /* 도우미 */

    /// @dev 시장 배포와 전원 토큰 승인
    function _deployMarket(MarketParams memory p) internal returns (Market deployed) {
        deployed = new Market(p);

        address[5] memory actors = [SUPPLIER, BORROWER, LIQUIDATOR, RECEIVER, OTHER];
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            MockERC20(p.loanToken).approve(address(deployed), type(uint256).max);
            MockERC20(p.collateralToken).approve(address(deployed), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev 시간 이동
    function _forward(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        loanToken.mint(user, assets);
        vm.prank(user);
        shares = market.deposit(assets, user);
    }

    function _supplyCollateral(address user, uint256 assets) internal {
        collateralToken.mint(user, assets);
        vm.prank(user);
        market.supplyCollateral(assets, user);
    }

    function _borrow(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = market.borrow(assets, user, user);
    }

    /// @dev 예치 10,000 USDC, 담보 5 WETH, 차입 7,000 USDC, 가격 2,000
    function _setUpExample() internal {
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        _borrow(BORROWER, 7_000e6);
    }

    /// @dev 청산 시도, 작은 잔액이 남으면 전부 청산
    function _liquidateOrFully(address liquidator, address borrower, uint256 seizedAssets, uint256 repaidShares)
        internal
        returns (uint256 seized, uint256 repaid)
    {
        vm.startPrank(liquidator);
        try market.liquidate(borrower, seizedAssets, repaidShares, "") returns (uint256 s, uint256 r) {
            (seized, repaid) = (s, r);
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            bool isDust =
                selector == IMarket.DebtBelowMinimum.selector || selector == IMarket.CollateralBelowMinimum.selector;
            assertTrue(isDust, "unexpected liquidate revert");
            (seized, repaid) = _liquidateFully(borrower);
        }
        vm.stopPrank();
    }

    /// @dev 전부 청산
    function _liquidateFully(address borrower) internal returns (uint256 seized, uint256 repaid) {
        try market.liquidate(borrower, 0, type(uint256).max, "") returns (uint256 s, uint256 r) {
            (seized, repaid) = (s, r);
        } catch (bytes memory err) {
            assertEq(bytes4(err), IMarket.SeizedExceedsCollateral.selector, "unexpected full liquidate revert");
            (seized, repaid) = market.liquidate(borrower, type(uint256).max, 0, "");
        }
    }

    /// @dev 담보로 빌릴 수 있는 최대 금액
    function _maxBorrow(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(collateral, price, ConstantsLib.ORACLE_PRICE_SCALE).wMulDown(LLTV);
    }
}
