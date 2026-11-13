// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IFlashLoanCallback {
    /// @notice 토큰을 받은 직후 호출
    /// @dev 끝나기 전에 시장에 assets 만큼 승인 필요
    function onFlashLoan(address token, uint256 assets, bytes calldata data) external;
}
