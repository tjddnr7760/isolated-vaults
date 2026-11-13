// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracle} from "./IOracle.sol";
import {IRateModel} from "./IRateModel.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    // 청산 기준 담보 비율 (WAD)
    uint256 lltv;
    uint256 minDebt;
    // 준비금 비율 (WAD)
    uint256 reserveFactor;
}

struct MarketState {
    // 예치 총액 (준비금 제외)
    uint128 totalSupplyAssets;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    // 마지막 이자 반영 시각
    uint128 lastUpdate;
    uint128 reserve;
    // 내림으로 아직 장부에 넣지 못한 이자 조각 (1e18 배율)
    uint128 interestRemainder;
}

struct Position {
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice 대리 권한 서명 메시지
struct Authorization {
    // 권한을 주는 주소 (서명자)
    address authorizer;
    address authorized;
    bool isAuthorized;
    uint256 nonce;
    uint256 deadline;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IMarket {
    /* ERRORS */

    error ZeroAddress();

    error ZeroAssets();

    error ZeroShares();

    /// @notice 두 입력 중 하나만 넣어야 함
    error InconsistentInput();

    error Unauthorized();

    error AlreadySet();

    error SignatureExpired(uint256 deadline);

    error InvalidSignature();

    /// @notice 담보 부족
    error Unhealthy();

    /// @notice 청산 대상이 아닌 포지션
    error HealthyPosition();

    error DebtBelowMinimum(uint256 debt, uint256 minDebt);

    error RepaidSharesExceedDebt(uint256 repaidShares, uint256 borrowShares);

    /// @notice 청산 뒤 남는 담보가 너무 작음
    error CollateralBelowMinimum(uint256 collateralValue, uint256 minValue);

    error SeizedExceedsCollateral(uint256 seizedAssets, uint256 collateral);

    error InsufficientLiquidity();

    error LltvTooHigh(uint256 lltv);

    error IdenticalTokens();

    error ZeroMinDebt();

    error ReserveFactorTooHigh(uint256 reserveFactor);

    error UnsupportedToken(address token);

    /* IMMUTABLES */

    function COLLATERAL_TOKEN() external view returns (address);

    function ORACLE() external view returns (IOracle);

    function IRM() external view returns (IRateModel);

    /// @notice 청산 기준 담보 비율 (WAD)
    function LLTV() external view returns (uint256);

    function MIN_DEBT() external view returns (uint256);

    /// @notice 준비금 비율 (WAD)
    function RESERVE_FACTOR() external view returns (uint256);

    /* AUTHORIZATION */

    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @dev 대리인은 내 이름으로 대출과 담보 꺼내기 가능
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    /// @dev 누구나 대신 제출 가능
    function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature) external;

    /* COLLATERAL MANAGEMENT */

    /// @dev 남의 포지션에도 가능
    function supplyCollateral(uint256 assets, address onBehalf) external;

    /// @dev 본인 또는 대리인만 가능
    function withdrawCollateral(uint256 assets, address onBehalf, address receiver) external;

    /* BORROW MANAGEMENT */

    /// @dev 본인 또는 대리인만 가능
    function borrow(uint256 assets, address onBehalf, address receiver) external returns (uint256 shares);

    /// @dev assets 와 shares 중 하나만 입력, 남의 빚도 가능
    /// @dev 빚보다 많이 넣으면 빚 전부만 상환
    function repay(uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256 repaidAssets, uint256 repaidShares);

    /* LIQUIDATION */

    /// @notice 청산, 빚을 대신 갚고 담보를 할인받아 가져감
    /// @dev seizedAssets 와 repaidShares 중 하나만 입력
    /// @dev 포지션보다 큰 값은 포지션 전부로 처리
    /// @dev 청산 뒤 너무 작은 빚이나 담보가 남으면 revert
    /// @dev data 가 있으면 담보를 보낸 뒤 호출자의 onLiquidate 호출
    function liquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
        external
        returns (uint256 seized, uint256 repaidAssets);

    /* FLASH LOAN */

    /// @dev 수수료 없음
    /// @dev 호출자의 onFlashLoan 호출
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    /* INTEREST */

    function accrueInterest() external;

    /* VIEW */

    function marketParams() external view returns (MarketParams memory);

    /// @notice 저장된 장부 (아직 반영 안 된 이자 제외)
    function marketState() external view returns (MarketState memory);

    /// @notice 이자를 반영한 장부
    function expectedMarketState() external view returns (MarketState memory);

    function position(address user) external view returns (Position memory);

    /// @notice 사용자의 빚 (아직 반영 안 된 이자 포함)
    function debtOf(address user) external view returns (uint256);

    /// @notice 건강 여부 (빚이 담보 가치 × LLTV 이하)
    function isHealthy(address user) external view returns (bool);

    /// @notice 빌려주거나 내줄 수 있는 현금
    function liquidity() external view returns (uint256);

    /// @notice 청산 보상 배수 (WAD)
    function liquidationIncentiveFactor() external view returns (uint256);
}
