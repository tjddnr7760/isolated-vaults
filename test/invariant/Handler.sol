// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "../../src/Market.sol";
import {IFlashLoanCallback} from "../../src/interfaces/IFlashLoanCallback.sol";
import {ILiquidateCallback} from "../../src/interfaces/ILiquidateCallback.sol";
import {IMarket, MarketState, Position} from "../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";

/// @notice 불변식 테스트 핸들러
/// @dev 실패할 호출은 미리 제외
contract Handler is Test, IFlashLoanCallback, ILiquidateCallback {
    using MathLib for uint256;

    uint256 internal constant MIN_PRICE = 500e6 * 1e36 / 1e18;
    uint256 internal constant MAX_PRICE = 4000e6 * 1e36 / 1e18;
    // 지분 가격 측정에 쓰는 지분 수
    uint256 internal constant PRICE_PROBE_SHARES = 1e24;

    Market internal immutable MARKET;
    MockERC20 internal immutable LOAN_TOKEN;
    MockERC20 internal immutable COLLATERAL_TOKEN;
    MockOracleAdapter internal immutable ORACLE;
    uint256 internal immutable MIN_DEBT;

    address[] public actors;

    // 호출 횟수
    mapping(bytes32 => uint256) public calls;
    uint256 public badDebtEvents;

    // 시장 밖에서 따로 센 장부 값
    uint256 public sumBorrowed;
    uint256 public sumRepaid;
    uint256 public sumBadDebt;
    // 장부를 바꾼 마지막 성공 시각
    uint256 public lastLedgerTouch;

    constructor(Market market, MockOracleAdapter oracle) {
        MARKET = market;
        LOAN_TOKEN = MockERC20(market.asset());
        COLLATERAL_TOKEN = MockERC20(market.COLLATERAL_TOKEN());
        ORACLE = oracle;
        MIN_DEBT = market.MIN_DEBT();
        lastLedgerTouch = market.marketState().lastUpdate;

        for (uint256 i; i < 4; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.startPrank(actor);
            LOAN_TOKEN.approve(address(market), type(uint256).max);
            COLLATERAL_TOKEN.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /* 앞뒤 비교 */

    /// @dev 호출 뒤 지분 가격과 준비금 감소 여부 확인
    modifier checksMonotonic() {
        uint256 sharePriceBefore = MARKET.convertToAssets(PRICE_PROBE_SHARES);
        uint256 reserveBefore = MARKET.expectedMarketState().reserve;
        _;
        assertGe(MARKET.convertToAssets(PRICE_PROBE_SHARES), sharePriceBefore, "share price decreased");
        assertGe(MARKET.expectedMarketState().reserve, reserveBefore, "reserve decreased");
    }

    function _touch() internal {
        lastLedgerTouch = block.timestamp;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /* 예치자 */

    function deposit(uint256 actorSeed, uint256 assets) external checksMonotonic {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1e6, 1e12);
        if (MARKET.previewDeposit(assets) == 0) return;
        LOAN_TOKEN.mint(actor, assets);

        vm.prank(actor);
        MARKET.deposit(assets, actor);
        _touch();
        ++calls["deposit"];
    }

    function mint(uint256 actorSeed, uint256 shares) external checksMonotonic {
        address actor = _actor(actorSeed);
        shares = bound(shares, 1e12, 1e18);
        LOAN_TOKEN.mint(actor, MARKET.previewMint(shares));

        vm.prank(actor);
        MARKET.mint(shares, actor);
        _touch();
        ++calls["mint"];
    }

    function withdraw(uint256 actorSeed, uint256 assets) external checksMonotonic {
        address actor = _actor(actorSeed);
        uint256 maxAssets = MARKET.maxWithdraw(actor);
        if (maxAssets == 0) return;
        assets = bound(assets, 1, maxAssets);

        // maxWithdraw 이하 인출은 항상 성공
        vm.prank(actor);
        MARKET.withdraw(assets, actor, actor);
        _touch();
        ++calls["withdraw"];
    }

    function redeem(uint256 actorSeed, uint256 shares) external checksMonotonic {
        address actor = _actor(actorSeed);
        uint256 maxShares = MARKET.maxRedeem(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        // maxRedeem 이하 인출은 항상 성공
        vm.prank(actor);
        MARKET.redeem(shares, actor, actor);
        _touch();
        ++calls["redeem"];
    }

    /* 차입자 */

    function supplyCollateral(uint256 actorSeed, uint256 assets) external checksMonotonic {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1e15, 1e21);
        COLLATERAL_TOKEN.mint(actor, assets);

        vm.prank(actor);
        MARKET.supplyCollateral(assets, actor);
        _touch();
        ++calls["supplyCollateral"];
    }

    function withdrawCollateral(uint256 actorSeed, uint256 assets) external checksMonotonic {
        address actor = _actor(actorSeed);
        uint256 collateral = MARKET.position(actor).collateral;
        if (collateral == 0) return;
        assets = bound(assets, 1, collateral);

        vm.prank(actor);
        try MARKET.withdrawCollateral(assets, actor, actor) {
            assertTrue(MARKET.isHealthy(actor), "unhealthy after withdrawCollateral");
            _touch();
            ++calls["withdrawCollateral"];
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IMarket.Unhealthy.selector, "withdrawCollateral: unexpected revert");
        }
    }

    function borrow(uint256 actorSeed, uint256 assets) external checksMonotonic {
        address actor = _actor(actorSeed);
        // 담보나 현금이 없으면 먼저 채우기
        if (MARKET.position(actor).collateral == 0) {
            COLLATERAL_TOKEN.mint(actor, 10e18);
            vm.prank(actor);
            MARKET.supplyCollateral(10e18, actor);
            _touch();
        }
        if (MARKET.liquidity() < MIN_DEBT) {
            address supplier = _actor(actorSeed % actors.length + 1);
            LOAN_TOKEN.mint(supplier, 100 * MIN_DEBT);
            vm.prank(supplier);
            MARKET.deposit(100 * MIN_DEBT, supplier);
            _touch();
        }
        // 한도의 110% 까지 선택
        uint256 limit = Math.mulDiv(MARKET.position(actor).collateral, ORACLE.price(), ConstantsLib.ORACLE_PRICE_SCALE)
            .wMulDown(MARKET.LLTV());
        uint256 debt = MARKET.debtOf(actor);
        uint256 room = limit > debt ? (limit - debt) * 11 / 10 : MIN_DEBT;
        assets = bound(assets, 1, Math.max(1, Math.min(MARKET.liquidity(), room)));

        _borrowAs(actor, actor, assets, debt);
    }

    /// @dev 대출 호출과 결과 확인
    function _borrowAs(address caller, address owner, uint256 assets, uint256 debtBefore) internal {
        bool isAllowed = caller == owner || MARKET.isAuthorized(owner, caller);

        vm.prank(caller);
        try MARKET.borrow(assets, owner, caller) {
            assertTrue(isAllowed, "unauthorized borrow succeeded");
            assertTrue(MARKET.isHealthy(owner), "unhealthy after borrow");
            uint256 debtAfter = MARKET.debtOf(owner);
            assertGe(debtAfter, MIN_DEBT, "debt below minimum after borrow");
            // 빚 증가가 빌린 금액 이상
            assertGe(debtAfter, debtBefore + assets, "debt grew less than borrowed");
            sumBorrowed += assets;
            _touch();
            ++calls[caller == owner ? bytes32("borrow") : bytes32("borrowByAgent")];
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (!isAllowed) {
                assertEq(selector, IMarket.Unauthorized.selector, "wrong revert for unauthorized borrow");
            } else {
                assertTrue(
                    selector == IMarket.Unhealthy.selector || selector == IMarket.DebtBelowMinimum.selector
                        || selector == IMarket.InsufficientLiquidity.selector,
                    "borrow: unexpected revert"
                );
            }
        }
    }

    function repay(uint256 actorSeed, uint256 assets, bool isFull) external checksMonotonic {
        address actor = _actor(actorSeed);
        uint256 debt = MARKET.debtOf(actor);
        if (debt == 0) return;
        LOAN_TOKEN.mint(actor, debt);

        if (isFull) {
            vm.prank(actor);
            // 큰 값 입력 시 전부 상환
            (uint256 paid,) = MARKET.repay(0, type(uint256).max, actor);
            assertEq(paid, debt, "full repay paid a different amount than the debt");
            assertEq(MARKET.debtOf(actor), 0, "debt left after full repay");
            sumRepaid += paid;
            _touch();
            ++calls["repayFull"];
            return;
        }

        assets = bound(assets, 1, debt);
        vm.prank(actor);
        try MARKET.repay(assets, 0, actor) returns (uint256 paid, uint256) {
            uint256 debtAfter = MARKET.debtOf(actor);
            assertTrue(debtAfter == 0 || debtAfter >= MIN_DEBT, "dust debt after repay");
            // 줄어든 빚이 낸 돈 이하
            assertGe(debtAfter + paid, debt, "repay erased more debt than paid");
            sumRepaid += paid;
            _touch();
            ++calls["repay"];
        } catch (bytes memory reason) {
            // 최소 부채 미만으로 남기는 상환만 거절
            assertEq(bytes4(reason), IMarket.DebtBelowMinimum.selector, "repay: unexpected revert");
        }
    }

    /* 대리 권한 */

    function setAuthorization(uint256 ownerSeed, uint256 agentSeed, bool newIsAuthorized) external checksMonotonic {
        address owner = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        if (owner == agent || MARKET.isAuthorized(owner, agent) == newIsAuthorized) return;

        vm.prank(owner);
        MARKET.setAuthorization(agent, newIsAuthorized);
        ++calls["setAuthorization"];
    }

    /// @dev 대리 권한이 있을 때만 남의 이름으로 대출
    function borrowByAgent(uint256 ownerSeed, uint256 agentSeed, uint256 assets) external checksMonotonic {
        address owner = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        if (owner == agent) return;
        assets = bound(assets, MIN_DEBT, 2 * MIN_DEBT);

        _borrowAs(agent, owner, assets, MARKET.debtOf(owner));
    }

    /// @dev 대리 권한이 있을 때만 남의 담보 회수
    function withdrawCollateralByAgent(uint256 ownerSeed, uint256 agentSeed, uint256 assets) external checksMonotonic {
        address owner = _actor(ownerSeed);
        address agent = _actor(agentSeed);
        uint256 collateral = MARKET.position(owner).collateral;
        if (owner == agent || collateral == 0) return;
        assets = bound(assets, 1, collateral);
        bool isAllowed = MARKET.isAuthorized(owner, agent);

        vm.prank(agent);
        try MARKET.withdrawCollateral(assets, owner, agent) {
            assertTrue(isAllowed, "unauthorized withdrawCollateral succeeded");
            assertTrue(MARKET.isHealthy(owner), "unhealthy after withdrawCollateral");
            _touch();
            ++calls["withdrawCollateralByAgent"];
        } catch (bytes memory reason) {
            bytes4 expected = isAllowed ? IMarket.Unhealthy.selector : IMarket.Unauthorized.selector;
            assertEq(bytes4(reason), expected, "withdrawCollateralByAgent: unexpected revert");
        }
    }

    /* 청산자 */

    /// @dev mode 로 담보량 지정, 지분 지정, 콜백 청산 선택
    function liquidate(uint256 liquidatorSeed, uint256 borrowerSeed, uint256 amount, uint256 mode) external {
        address borrower = _findUnhealthy(borrowerSeed);
        if (borrower == address(0)) return;
        uint256 price = ORACLE.price();
        uint256 debt = MARKET.debtOf(borrower);
        (uint256 seized, uint256 shares) = _pickLiquidationAmount(borrower, debt, price, amount, mode % 3 == 1);
        if (seized == 0 && shares == 0) return;
        bool useCallback = mode % 3 == 2;
        address liquidator = useCallback ? address(this) : _actor(liquidatorSeed);
        if (!useCallback) LOAN_TOKEN.mint(liquidator, debt);

        MarketState memory stateBefore = MARKET.expectedMarketState();
        uint256 sharePriceBefore = MARKET.convertToAssets(PRICE_PROBE_SHARES);
        vm.recordLogs();
        (uint256 seizedAssets, uint256 repaidAssets) = _liquidateOrFully(liquidator, borrower, seized, shares);
        (uint256 badDebtAssets, uint256 reserveUsed) = _readLiquidateEvent(seizedAssets, repaidAssets);
        sumRepaid += repaidAssets;
        sumBadDebt += badDebtAssets;
        _touch();

        _checkNoDust(borrower, price);
        // 받은 담보 가치 ≤ 갚은 자산 × LIF + 1
        assertLe(
            Math.mulDiv(seizedAssets, price, ConstantsLib.ORACLE_PRICE_SCALE),
            repaidAssets.wMulDown(MARKET.liquidationIncentiveFactor()) + 1,
            "incentive above factor"
        );
        _checkBadDebtAccounting(stateBefore, sharePriceBefore, badDebtAssets, reserveUsed);
        if (badDebtAssets > 0) ++badDebtEvents;
        bytes32 kind = useCallback ? bytes32("liquidateCallback") : bytes32("liquidate");
        ++calls[shares > 0 && !useCallback ? bytes32("liquidateShares") : kind];
    }

    /// @dev 청산 가능한 행위자 찾기, 없으면 0 주소
    function _findUnhealthy(uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address candidate = _actor(seed % actors.length + i);
            if (!MARKET.isHealthy(candidate)) return candidate;
        }
        return address(0);
    }

    /// @dev 실패하지 않을 청산 금액 선택
    function _pickLiquidationAmount(address borrower, uint256 debt, uint256 price, uint256 amount, bool byShares)
        internal
        view
        returns (uint256 seized, uint256 shares)
    {
        Position memory pos = MARKET.position(borrower);
        uint256 lif = MARKET.liquidationIncentiveFactor();
        if (byShares) {
            // 담보 가치의 99% 로 갚을 수 있는 빚까지
            uint256 maxAssets =
                Math.mulDiv(pos.collateral, price, ConstantsLib.ORACLE_PRICE_SCALE).wDivDown(lif) * 99 / 100;
            uint256 maxShares = Math.min(pos.borrowShares, Math.mulDiv(maxAssets, pos.borrowShares, debt));
            if (maxShares > 0) {
                shares = amount % 3 == 0 ? maxShares : bound(amount, 1, maxShares);
                return (0, shares);
            }
        }
        // 빚의 99% 어치 담보까지
        uint256 maxSeizable = Math.min(
            pos.collateral, Math.mulDiv((debt * 99 / 100).wMulDown(lif), ConstantsLib.ORACLE_PRICE_SCALE, price)
        );
        if (maxSeizable == 0) return (0, 0);
        // 3번에 1번은 최대 담보량
        seized = amount % 3 == 0 ? maxSeizable : bound(amount, 1, maxSeizable);
    }

    /// @dev 청산 시도, 작은 잔액이 남으면 전부 청산
    function _liquidateOrFully(address liquidator, address borrower, uint256 seized, uint256 shares)
        internal
        returns (uint256 seizedAssets, uint256 repaidAssets)
    {
        bool useCallback = liquidator == address(this);
        bytes memory data = useCallback ? bytes("callback") : bytes("");
        if (!useCallback) vm.startPrank(liquidator);
        try MARKET.liquidate(borrower, seized, shares, data) returns (uint256 s, uint256 r) {
            (seizedAssets, repaidAssets) = (s, r);
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            bool isDust =
                selector == IMarket.DebtBelowMinimum.selector || selector == IMarket.CollateralBelowMinimum.selector;
            assertTrue(isDust, "unexpected liquidate revert");
            try MARKET.liquidate(borrower, 0, type(uint256).max, data) returns (uint256 s, uint256 r) {
                (seizedAssets, repaidAssets) = (s, r);
            } catch (bytes memory fullErr) {
                assertEq(bytes4(fullErr), IMarket.SeizedExceedsCollateral.selector, "unexpected full liquidate revert");
                (seizedAssets, repaidAssets) = MARKET.liquidate(borrower, type(uint256).max, 0, data);
            }
            ++calls["liquidateFully"];
        }
        if (!useCallback) vm.stopPrank();
    }

    /// @dev 청산 이벤트에서 부실 금액과 준비금 사용액 읽기
    function _readLiquidateEvent(uint256 seizedAssets, uint256 repaidAssets)
        internal
        returns (uint256 badDebtAssets, uint256 reserveUsed)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(MARKET) || logs[i].topics[0] != EventsLib.Liquidate.selector) continue;
            uint256 repaidInEvent;
            uint256 seizedInEvent;
            (repaidInEvent,, seizedInEvent, badDebtAssets, reserveUsed) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertEq(repaidInEvent, repaidAssets, "Liquidate event: repaidAssets");
            assertEq(seizedInEvent, seizedAssets, "Liquidate event: seizedAssets");
            ++found;
        }
        assertEq(found, 1, "Liquidate event count");
    }

    /// @dev 청산 뒤 남은 빚과 담보 가치가 최소 부채 이상인지 확인
    function _checkNoDust(address borrower, uint256 price) internal view {
        Position memory pos = MARKET.position(borrower);
        if (pos.borrowShares == 0) return;
        assertGe(MARKET.debtOf(borrower), MIN_DEBT, "dust debt after liquidation");
        assertGe(
            Math.mulDiv(pos.collateral, price, ConstantsLib.ORACLE_PRICE_SCALE),
            MIN_DEBT,
            "dust collateral after liquidation"
        );
    }

    /// @dev 부실을 준비금이 먼저 흡수하는지 확인
    function _checkBadDebtAccounting(
        MarketState memory stateBefore,
        uint256 sharePriceBefore,
        uint256 badDebtAssets,
        uint256 reserveUsed
    ) internal view {
        MarketState memory stateAfter = MARKET.marketState();
        assertEq(reserveUsed, Math.min(stateBefore.reserve, badDebtAssets), "reserve must absorb first");
        assertEq(stateBefore.reserve - stateAfter.reserve, reserveUsed, "reserve changed by a different amount");
        assertEq(
            stateBefore.totalSupplyAssets - stateAfter.totalSupplyAssets,
            badDebtAssets - reserveUsed,
            "suppliers absorb only the rest"
        );
        if (badDebtAssets == reserveUsed) {
            assertGe(MARKET.convertToAssets(PRICE_PROBE_SHARES), sharePriceBefore, "share price decreased");
        }
    }

    function onLiquidate(uint256 repaidAssets, uint256, bytes calldata) external {
        // 시장이 아닌 호출 무시
        if (msg.sender != address(MARKET)) return;
        // 갚을 만큼 대출 토큰 발행
        LOAN_TOKEN.mint(address(this), repaidAssets);
        LOAN_TOKEN.approve(address(MARKET), repaidAssets);
    }

    /* 플래시론 */

    /// @dev 빌렸다 돌려준 뒤 잔액과 장부 유지 확인
    function flashLoan(uint256 assets, bool isCollateral) external checksMonotonic {
        MockERC20 token = isCollateral ? COLLATERAL_TOKEN : LOAN_TOKEN;
        uint256 balanceBefore = token.balanceOf(address(MARKET));
        if (balanceBefore == 0) return;
        assets = bound(assets, 1, balanceBefore);
        bytes32 stateBefore = keccak256(abi.encode(MARKET.marketState()));

        MARKET.flashLoan(address(token), assets, "");

        assertEq(token.balanceOf(address(MARKET)), balanceBefore, "balance changed by flashLoan");
        assertEq(keccak256(abi.encode(MARKET.marketState())), stateBefore, "flashLoan changed the ledger");
        ++calls["flashLoan"];
    }

    function onFlashLoan(address token, uint256 assets, bytes calldata) external {
        // 시장이 아닌 호출 무시
        if (msg.sender != address(MARKET)) return;
        MockERC20(token).approve(address(MARKET), assets);
    }

    /* 환경 */

    function setPrice(uint256 price) external checksMonotonic {
        // 지금 가격의 60% ~ 130% 로 변경
        uint256 current = ORACLE.price();
        price = bound(price, current * 60 / 100, current * 130 / 100);
        ORACLE.setPrice(bound(price, MIN_PRICE, MAX_PRICE));
        ++calls["setPrice"];
    }

    function forward(uint256 secs) external checksMonotonic {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        ++calls["forward"];
    }

    function accrueInterest() external checksMonotonic {
        MARKET.accrueInterest();
        assertEq(MARKET.marketState().lastUpdate, block.timestamp, "lastUpdate not now");
        _touch();
        ++calls["accrueInterest"];
    }

    /// @dev 토큰을 직접 보내도 지분 가격과 장부 유지
    function donate(uint256 assets) external {
        assets = bound(assets, 1, 1e12);
        uint256 totalAssetsBefore = MARKET.totalAssets();
        LOAN_TOKEN.mint(address(MARKET), assets);

        assertEq(MARKET.totalAssets(), totalAssetsBefore, "donation changed totalAssets");
        ++calls["donate"];
    }
}
