// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MarketParams} from "./IMarket.sol";

interface IMarketFactory {
    /* ERRORS */

    error AlreadyEnabled();

    error LltvTooHigh(uint256 lltv);

    /// @notice 컨트랙트가 아닌 주소
    error NoCode(address account);

    error LltvNotEnabled(uint256 lltv);

    error IrmNotEnabled(address irm);

    error OracleNotEnabled(address oracle);

    error OracleTokenMismatch(address oracle);

    error MarketAlreadyCreated(address market);

    /* OWNER */

    /// @dev 소유자 전용
    function enableLltv(uint256 lltv) external;

    /// @dev 소유자 전용
    function enableIrm(address irm) external;

    /// @dev 소유자 전용
    function enableOracle(address oracle) external;

    /* MARKET CREATION */

    /// @dev 누구나 호출 가능, 승인된 값만 사용 가능
    function createMarket(MarketParams memory p) external returns (address market);

    /* VIEW */

    function isLltvEnabled(uint256 lltv) external view returns (bool);

    function isIrmEnabled(address irm) external view returns (bool);

    function isOracleEnabled(address oracle) external view returns (bool);

    /// @notice 이 팩토리가 만든 시장인지 여부
    function isMarket(address market) external view returns (bool);

    function computeMarketAddress(MarketParams memory p) external view returns (address);
}
