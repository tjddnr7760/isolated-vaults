// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Market} from "../../../src/Market.sol";
import {IHookReceiver} from "./HookToken.sol";

/// @notice 토큰 훅 안에서 시장을 다시 부르는 공격자
contract ReentrantAttacker is IHookReceiver {
    Market internal immutable MARKET;

    bool public isArmed;
    uint256 public hookCalls;
    // 막힌 재진입 횟수와 마지막 에러
    uint256 public blockedCalls;
    bytes4 public lastSelector;
    // 훅 안에서 읽은 뷰 값
    uint256 public totalAssetsInHook;
    uint256 public sharePriceInHook;
    uint256 public totalSupplyAssetsInHook;

    constructor(Market market) {
        MARKET = market;
        IERC20(market.asset()).approve(address(market), type(uint256).max);
        IERC20(market.COLLATERAL_TOKEN()).approve(address(market), type(uint256).max);
    }

    function arm(bool armed) external {
        isArmed = armed;
    }

    function deposit(uint256 assets) external {
        MARKET.deposit(assets, address(this));
    }

    function withdraw(uint256 assets) external {
        MARKET.withdraw(assets, address(this), address(this));
    }

    function supplyCollateral(uint256 assets) external {
        MARKET.supplyCollateral(assets, address(this));
    }

    function borrow(uint256 assets) external {
        MARKET.borrow(assets, address(this), address(this));
    }

    function onTokenTransfer(address, address, uint256) external {
        if (!isArmed) return;
        ++hookCalls;

        totalAssetsInHook = MARKET.totalAssets();
        sharePriceInHook = MARKET.convertToAssets(1e24);
        totalSupplyAssetsInHook = MARKET.marketState().totalSupplyAssets;

        _try(abi.encodeCall(MARKET.deposit, (1e6, address(this))));
        _try(abi.encodeCall(MARKET.mint, (1e12, address(this))));
        _try(abi.encodeCall(MARKET.withdraw, (1, address(this), address(this))));
        _try(abi.encodeCall(MARKET.redeem, (1, address(this), address(this))));
        _try(abi.encodeCall(MARKET.borrow, (1e6, address(this), address(this))));
        _try(abi.encodeCall(MARKET.repay, (1, 0, address(this))));
        _try(abi.encodeCall(MARKET.supplyCollateral, (1, address(this))));
        _try(abi.encodeCall(MARKET.withdrawCollateral, (1, address(this), address(this))));
        _try(abi.encodeCall(MARKET.liquidate, (address(this), 1, 0, "")));
        _try(abi.encodeCall(MARKET.accrueInterest, ()));
        _try(abi.encodeCall(MARKET.flashLoan, (MARKET.asset(), 1, "")));
        _try(abi.encodeCall(MARKET.setAuthorization, (address(1), true)));
    }

    function _try(bytes memory data) internal {
        (bool ok, bytes memory reason) = address(MARKET).call(data);
        if (!ok) {
            ++blockedCalls;
            lastSelector = bytes4(reason);
        }
    }
}
