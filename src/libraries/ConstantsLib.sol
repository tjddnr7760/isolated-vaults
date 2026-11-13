// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

library ConstantsLib {
    /// @dev 초당 금리 상한 (WAD), 연 200%
    uint256 internal constant MAX_BORROW_RATE = uint256(2e18) / 365 days;

    /// @dev 준비금 비율 상한 (WAD), 25%
    uint256 internal constant MAX_RESERVE_FACTOR = 0.25e18;

    /// @dev 청산 보상 계산 계수 (WAD)
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    /// @dev 청산 보상 상한 (WAD), 15%
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;

    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev 예치 지분의 추가 자릿수
    uint8 internal constant DECIMALS_OFFSET = 6;

    string internal constant EIP712_VERSION = "1";

    bytes32 internal constant AUTHORIZATION_TYPEHASH = keccak256(
        "Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)"
    );

    string internal constant SHARE_NAME = "Lending Market Share";

    string internal constant SHARE_SYMBOL = "LMS";
}
