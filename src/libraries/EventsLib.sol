// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MarketParams} from "../interfaces/IMarket.sol";

library EventsLib {
    event SetAuthorization(
        address indexed caller, address indexed authorizer, address indexed authorized, bool newIsAuthorized
    );

    event SupplyCollateral(address indexed caller, address indexed onBehalf, uint256 assets);

    event WithdrawCollateral(
        address indexed caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );

    event Borrow(
        address indexed caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares
    );

    event Repay(address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);

    /// @param badDebtAssets 못 받게 된 빚
    /// @param reserveUsed 그중 준비금이 메운 금액
    event Liquidate(
        address indexed caller,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets,
        uint256 badDebtAssets,
        uint256 reserveUsed
    );

    event EnableLltv(uint256 lltv);

    event EnableIrm(address indexed irm);

    event EnableOracle(address indexed oracle);

    event CreateMarket(address indexed market, address indexed creator, MarketParams params);

    event FlashLoan(address indexed caller, address indexed token, uint256 assets);

    /// @param reserveAssets 이자 중 준비금 몫
    event AccrueInterest(uint256 borrowRate, uint256 interest, uint256 reserveAssets);
}
