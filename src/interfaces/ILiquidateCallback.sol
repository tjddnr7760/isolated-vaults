// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface ILiquidateCallback {
    /// @notice 담보를 받은 직후, 갚을 돈을 내기 직전에 호출
    /// @dev 끝나기 전에 시장에 repaidAssets 만큼 승인 필요
    function onLiquidate(uint256 repaidAssets, uint256 seizedAssets, bytes calldata data) external;
}
