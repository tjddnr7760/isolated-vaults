// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Market} from "../../src/Market.sol";
import {IFlashLoanCallback} from "../../src/interfaces/IFlashLoanCallback.sol";

/// @notice 테스트용 플래시론 수령자
contract FlashBorrower is IFlashLoanCallback {
    enum Mode {
        Repay,
        NoRepay,
        Reenter
    }

    Market internal immutable MARKET;

    Mode public mode;
    // 콜백 안에서 본 값
    address public tokenInCallback;
    uint256 public assetsInCallback;
    uint256 public balanceInCallback;
    bytes public dataInCallback;
    // 막힌 재진입 횟수와 마지막 에러
    uint256 public blockedCalls;
    bytes4 public lastSelector;

    constructor(Market market) {
        MARKET = market;
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        MARKET.flashLoan(token, assets, data);
    }

    function onFlashLoan(address token, uint256 assets, bytes calldata data) external {
        tokenInCallback = token;
        assetsInCallback = assets;
        balanceInCallback = IERC20(token).balanceOf(address(this));
        dataInCallback = data;

        if (mode == Mode.Reenter) {
            // 빌린 돈으로 시장 재진입 시도
            IERC20(token).approve(address(MARKET), type(uint256).max);
            _try(abi.encodeCall(MARKET.deposit, (assets, address(this))));
            _try(abi.encodeCall(MARKET.supplyCollateral, (assets, address(this))));
            _try(abi.encodeCall(MARKET.repay, (assets, 0, address(this))));
            _try(abi.encodeCall(MARKET.flashLoan, (token, 1, "")));
        }

        if (mode != Mode.NoRepay) IERC20(token).approve(address(MARKET), assets);
    }

    function _try(bytes memory data) internal {
        (bool ok, bytes memory reason) = address(MARKET).call(data);
        if (!ok) {
            ++blockedCalls;
            lastSelector = bytes4(reason);
        }
    }
}
