// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IRateModel {
    /// @notice 초당 대출 금리 (WAD)
    function borrowRate(uint256 totalSupplyAssets, uint256 totalBorrowAssets) external view returns (uint256);
}
