// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MarketState, Position} from "../../src/interfaces/IMarket.sol";
import {BaseTest} from "../BaseTest.sol";
import {Handler} from "./Handler.sol";

contract MarketInvariantTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(market, oracle);
        targetContract(address(handler));
        // 콜백 함수는 호출 대상에서 제외
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = Handler.onFlashLoan.selector;
        excluded[1] = Handler.onLiquidate.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }

    function _sumPositions() internal view returns (uint256 borrowShares, uint256 collateral, uint256 debt) {
        uint256 length = handler.actorsLength();
        for (uint256 i; i < length; ++i) {
            address actor = handler.actors(i);
            Position memory pos = market.position(actor);
            borrowShares += pos.borrowShares;
            collateral += pos.collateral;
            debt += market.debtOf(actor);
        }
    }

    /// @dev 대출 토큰 잔액이 장부의 현금과 준비금 이상
    function invariant_LoanBalanceCoversLedger() public view {
        MarketState memory state = market.marketState();

        assertGe(
            loanToken.balanceOf(address(market)) + state.totalBorrowAssets,
            uint256(state.totalSupplyAssets) + state.reserve,
            "loan balance below ledger"
        );
    }

    /// @dev 담보 잔액이 모든 포지션의 담보 합 이상
    function invariant_CollateralBalanceCoversPositions() public view {
        (, uint256 collateral,) = _sumPositions();

        assertGe(collateralToken.balanceOf(address(market)), collateral, "collateral balance below positions");
    }

    /// @dev 총 차입이 총 예치와 준비금의 합 이하
    function invariant_TotalBorrowLeSupplyPlusReserve() public view {
        MarketState memory state = market.marketState();

        assertLe(
            state.totalBorrowAssets,
            uint256(state.totalSupplyAssets) + state.reserve,
            "total borrow above supply plus reserve"
        );
    }

    /// @dev 포지션 차입 지분의 합이 총 차입 지분
    function invariant_BorrowSharesSumMatchesTotal() public view {
        (uint256 borrowShares,,) = _sumPositions();

        assertEq(borrowShares, market.marketState().totalBorrowShares, "borrow shares sum mismatch");
    }

    /// @dev 빌려 준 돈은 상환이나 부실 처리 전까지 장부에 유지
    function invariant_BorrowedIsRepaidOrWrittenOff() public view {
        MarketState memory state = market.marketState();

        assertGe(
            uint256(state.totalBorrowAssets) + handler.sumRepaid() + handler.sumBadDebt(),
            handler.sumBorrowed(),
            "borrowed assets left the ledger"
        );
    }

    /// @dev 차입자 빚의 합이 총 차입을 포지션 수보다 많이 넘지 않음
    function invariant_DebtSumNotInflated() public view {
        (,, uint256 debt) = _sumPositions();
        MarketState memory state = market.expectedMarketState();

        assertLe(debt, uint256(state.totalBorrowAssets) + handler.actorsLength(), "debt inflated");
    }

    /// @dev 담보가 0 인 포지션은 빚도 0
    function invariant_CollateralZeroImpliesNoDebt() public view {
        uint256 length = handler.actorsLength();
        for (uint256 i; i < length; ++i) {
            Position memory pos = market.position(handler.actors(i));
            if (pos.collateral == 0) assertEq(pos.borrowShares, 0, "debt without collateral");
        }
    }

    /// @dev lastUpdate 가 장부를 바꾼 마지막 호출 시각과 일치
    function invariant_LastUpdateIsLastLedgerTouch() public view {
        assertEq(market.marketState().lastUpdate, handler.lastLedgerTouch(), "lastUpdate not at last ledger change");
    }

    /// @dev max 뷰는 현금 이하이고 revert 없음
    function invariant_MaxViewsBoundedByLiquidity() public view {
        uint256 liquidity = market.liquidity();
        uint256 length = handler.actorsLength();
        for (uint256 i; i < length; ++i) {
            address actor = handler.actors(i);
            assertLe(market.maxWithdraw(actor), liquidity, "maxWithdraw above liquidity");
            assertLe(market.previewRedeem(market.maxRedeem(actor)), liquidity, "maxRedeem above liquidity");
        }
    }
}
