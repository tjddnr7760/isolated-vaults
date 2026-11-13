// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IOracle {
    function LOAN_TOKEN() external view returns (address);

    function COLLATERAL_TOKEN() external view returns (address);

    /// @notice 담보 1 단위의 가격 (대출 토큰 단위, 1e36 배율)
    /// @dev 가격을 믿을 수 없으면 revert
    function price() external view returns (uint256);
}
