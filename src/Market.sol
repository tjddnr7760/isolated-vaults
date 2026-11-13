// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib, WAD} from "morpho-blue/libraries/MathLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {UtilsLib} from "morpho-blue/libraries/UtilsLib.sol";

import {IFlashLoanCallback} from "./interfaces/IFlashLoanCallback.sol";
import {ILiquidateCallback} from "./interfaces/ILiquidateCallback.sol";
import {IMarket, MarketParams, MarketState, Position, Authorization, Signature} from "./interfaces/IMarket.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IRateModel} from "./interfaces/IRateModel.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice 대출 시장 하나를 담는 ERC-4626 금고
/// @dev 함수 안의 순서: 이자 반영, 입력 검사, 장부 변경, 변경 뒤 검사, 이벤트, 토큰 이동
contract Market is IMarket, ERC4626, ReentrancyGuard, EIP712, Nonces {
    using MathLib for uint128;
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    address public immutable COLLATERAL_TOKEN;

    IOracle public immutable ORACLE;

    IRateModel public immutable IRM;

    uint256 public immutable LLTV;

    uint256 public immutable MIN_DEBT;

    uint256 public immutable RESERVE_FACTOR;

    /* STORAGE */

    MarketState internal _marketState;

    mapping(address => mapping(address => bool)) public isAuthorized;

    mapping(address => Position) internal _position;

    /* CONSTRUCTOR */

    constructor(MarketParams memory p)
        ERC4626(IERC20(p.loanToken))
        ERC20(ConstantsLib.SHARE_NAME, ConstantsLib.SHARE_SYMBOL)
        EIP712(ConstantsLib.SHARE_NAME, ConstantsLib.EIP712_VERSION)
    {
        require(
            p.loanToken != address(0) && p.collateralToken != address(0) && p.oracle != address(0)
                && p.irm != address(0),
            ZeroAddress()
        );
        require(p.loanToken != p.collateralToken, IdenticalTokens());
        require(p.lltv < WAD, LltvTooHigh(p.lltv));
        require(p.minDebt != 0, ZeroMinDebt());
        require(p.reserveFactor <= ConstantsLib.MAX_RESERVE_FACTOR, ReserveFactorTooHigh(p.reserveFactor));

        COLLATERAL_TOKEN = p.collateralToken;
        ORACLE = IOracle(p.oracle);
        IRM = IRateModel(p.irm);
        LLTV = p.lltv;
        MIN_DEBT = p.minDebt;
        RESERVE_FACTOR = p.reserveFactor;

        _marketState.lastUpdate = block.timestamp.toUint128();
    }

    /* ERC4626 (PUBLIC) */

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.deposit(assets, receiver);
    }

    /// @notice 지분 수를 정해서 예치
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice 지분 수를 정해서 인출
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice 예치 총액 (아직 반영 안 된 이자 포함)
    function totalAssets() public view override returns (uint256) {
        (MarketState memory state,,,) = _accruedState();
        return state.totalSupplyAssets;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        (MarketState memory state,,,) = _accruedState();
        return UtilsLib.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), _liquidity(state));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        (MarketState memory state,,,) = _accruedState();
        return UtilsLib.min(balanceOf(owner), _convertToShares(_liquidity(state), Math.Rounding.Floor));
    }

    /* AUTHORIZATION */

    function setAuthorization(address authorized, bool newIsAuthorized) external nonReentrant {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], AlreadySet());

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature)
        external
        nonReentrant
    {
        require(block.timestamp <= authorization.deadline, SignatureExpired(authorization.deadline));
        _useCheckedNonce(authorization.authorizer, authorization.nonce);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(ConstantsLib.AUTHORIZATION_TYPEHASH, authorization)));
        address signer = ECDSA.recover(digest, signature.v, signature.r, signature.s);
        require(signer == authorization.authorizer, InvalidSignature());

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /* COLLATERAL MANAGEMENT */

    function supplyCollateral(uint256 assets, address onBehalf) external nonReentrant {
        _accrueInterest();

        require(assets != 0, ZeroAssets());
        require(onBehalf != address(0), ZeroAddress());

        _position[onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(msg.sender, onBehalf, assets);

        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(uint256 assets, address onBehalf, address receiver) external nonReentrant {
        MarketState memory state = _accrueInterest();

        require(assets != 0, ZeroAssets());
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized());

        Position memory pos = _position[onBehalf];
        pos.collateral -= assets.toUint128();
        _position[onBehalf] = pos;

        require(_isHealthy(pos, state), Unhealthy());

        emit EventsLib.WithdrawCollateral(msg.sender, onBehalf, receiver, assets);

        IERC20(COLLATERAL_TOKEN).safeTransfer(receiver, assets);
    }

    /* BORROW MANAGEMENT */

    function borrow(uint256 assets, address onBehalf, address receiver) external nonReentrant returns (uint256 shares) {
        MarketState memory state = _accrueInterest();

        require(assets != 0, ZeroAssets());
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized());

        shares = assets.toSharesUp(state.totalBorrowAssets, state.totalBorrowShares);
        Position memory pos = _position[onBehalf];
        pos.borrowShares += shares.toUint128();
        state.totalBorrowShares += shares.toUint128();
        state.totalBorrowAssets += assets.toUint128();
        _position[onBehalf] = pos;
        _marketState = state;

        require(_isHealthy(pos, state), Unhealthy());
        uint256 debt = _debt(pos, state);
        require(debt >= MIN_DEBT, DebtBelowMinimum(debt, MIN_DEBT));
        require(state.totalBorrowAssets <= state.totalSupplyAssets, InsufficientLiquidity());

        emit EventsLib.Borrow(msg.sender, onBehalf, receiver, assets, shares);

        IERC20(asset()).safeTransfer(receiver, assets);
    }

    function repay(uint256 assets, uint256 shares, address onBehalf) external nonReentrant returns (uint256, uint256) {
        MarketState memory state = _accrueInterest();

        require(UtilsLib.exactlyOneZero(assets, shares), InconsistentInput());
        require(onBehalf != address(0), ZeroAddress());

        bool byShares = assets == 0;
        if (!byShares) shares = assets.toSharesDown(state.totalBorrowAssets, state.totalBorrowShares);
        Position memory pos = _position[onBehalf];
        // 빚보다 많으면 빚 전부만 상환
        bool capped = shares > pos.borrowShares;
        if (capped) shares = pos.borrowShares;
        if (byShares || capped) assets = shares.toAssetsUp(state.totalBorrowAssets, state.totalBorrowShares);
        pos.borrowShares -= shares.toUint128();
        state.totalBorrowShares -= shares.toUint128();
        // 올림으로 총 차입보다 1 클 수 있음
        state.totalBorrowAssets = uint256(state.totalBorrowAssets).zeroFloorSub(assets).toUint128();
        _position[onBehalf] = pos;
        _marketState = state;

        uint256 debt = _debt(pos, state);
        require(debt == 0 || debt >= MIN_DEBT, DebtBelowMinimum(debt, MIN_DEBT));

        emit EventsLib.Repay(msg.sender, onBehalf, assets, shares);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* LIQUIDATION */

    function liquidate(address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata data)
        external
        nonReentrant
        returns (uint256, uint256)
    {
        MarketState memory state = _accrueInterest();

        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), InconsistentInput());
        Position memory pos = _position[borrower];
        uint256 collateralPrice = ORACLE.price();
        require(!_isHealthy(pos, state, collateralPrice), HealthyPosition());

        uint256 repaidAssets;
        (seizedAssets, repaidAssets) = _liquidate(borrower, pos, state, seizedAssets, repaidShares, collateralPrice);

        IERC20(COLLATERAL_TOKEN).safeTransfer(msg.sender, seizedAssets);
        // 받은 담보로 갚을 돈을 마련할 기회
        if (data.length > 0) ILiquidateCallback(msg.sender).onLiquidate(repaidAssets, seizedAssets, data);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FLASH LOAN */

    function flashLoan(address token, uint256 assets, bytes calldata data) external nonReentrant {
        // 장부를 건드리지 않아 이자 반영 없음

        require(assets != 0, ZeroAssets());
        require(token == asset() || token == COLLATERAL_TOKEN, UnsupportedToken(token));

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);
        IFlashLoanCallback(msg.sender).onFlashLoan(token, assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* INTEREST */

    function accrueInterest() external nonReentrant {
        _accrueInterest();
    }

    /* VIEW */

    function marketParams() external view returns (MarketParams memory) {
        return MarketParams({
            loanToken: asset(),
            collateralToken: COLLATERAL_TOKEN,
            oracle: address(ORACLE),
            irm: address(IRM),
            lltv: LLTV,
            minDebt: MIN_DEBT,
            reserveFactor: RESERVE_FACTOR
        });
    }

    function marketState() external view returns (MarketState memory) {
        return _marketState;
    }

    function expectedMarketState() external view returns (MarketState memory state) {
        (state,,,) = _accruedState();
    }

    function position(address user) external view returns (Position memory) {
        return _position[user];
    }

    function debtOf(address user) external view returns (uint256) {
        (MarketState memory state,,,) = _accruedState();
        return _debt(_position[user], state);
    }

    function isHealthy(address user) external view returns (bool) {
        (MarketState memory state,,,) = _accruedState();
        return _isHealthy(_position[user], state);
    }

    function liquidity() external view returns (uint256) {
        (MarketState memory state,,,) = _accruedState();
        return _liquidity(state);
    }

    function liquidationIncentiveFactor() external view returns (uint256) {
        return _liquidationIncentiveFactor();
    }

    /* ERC4626 (INTERNAL) */

    /// @dev 예치 지분의 추가 자릿수
    function _decimalsOffset() internal pure override returns (uint8) {
        return ConstantsLib.DECIMALS_OFFSET;
    }

    /// @dev 장부를 먼저 바꾸고 토큰을 나중에 받음
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        require(shares != 0, ZeroShares());

        _marketState.totalSupplyAssets += assets.toUint128();
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);

        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(receiver != address(0), ZeroAddress());
        if (caller != owner) _spendAllowance(owner, caller, shares);
        MarketState memory state = _marketState;
        // 앞의 검사와 같은 값의 이중 확인
        require(assets <= _liquidity(state), InsufficientLiquidity());

        _burn(owner, shares);
        _marketState.totalSupplyAssets = state.totalSupplyAssets - assets.toUint128();

        emit Withdraw(caller, receiver, owner, assets, shares);

        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /* INTERNAL */

    /// @dev 본인 또는 대리인 여부
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    function _accrueInterest() internal returns (MarketState memory state) {
        uint256 borrowRate;
        uint256 interest;
        uint256 reserveAssets;
        (state, borrowRate, interest, reserveAssets) = _accruedState();

        if (state.lastUpdate == _marketState.lastUpdate) return state;

        _marketState = state;

        emit EventsLib.AccrueInterest(borrowRate, interest, reserveAssets);
    }

    /// @dev 이자를 반영한 장부 계산 (저장하지 않음)
    function _accruedState()
        internal
        view
        returns (MarketState memory state, uint256 borrowRate, uint256 interest, uint256 reserveAssets)
    {
        state = _marketState;
        uint256 elapsed = block.timestamp - state.lastUpdate;
        if (elapsed == 0) return (state, 0, 0, 0);

        if (state.totalBorrowAssets != 0) {
            borrowRate = UtilsLib.min(
                IRM.borrowRate(state.totalSupplyAssets, state.totalBorrowAssets), ConstantsLib.MAX_BORROW_RATE
            );
            // 내림으로 버린 조각을 다음 반영으로 넘김
            uint256 accrued =
                uint256(state.totalBorrowAssets) * borrowRate.wTaylorCompounded(elapsed) + state.interestRemainder;
            interest = accrued / WAD;
            state.interestRemainder = (accrued % WAD).toUint128();
            reserveAssets = interest.mulDivUp(RESERVE_FACTOR, WAD);

            state.totalBorrowAssets += interest.toUint128();
            state.totalSupplyAssets += (interest - reserveAssets).toUint128();
            state.reserve += reserveAssets.toUint128();
        }

        state.lastUpdate = block.timestamp.toUint128();
    }

    function _liquidate(
        address borrower,
        Position memory pos,
        MarketState memory state,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 collateralPrice
    ) internal returns (uint256, uint256 repaidAssets) {
        uint256 incentiveFactor = _liquidationIncentiveFactor();
        // 포지션보다 큰 입력은 포지션 전부로 낮춤
        seizedAssets = UtilsLib.min(seizedAssets, pos.collateral);
        repaidShares = UtilsLib.min(repaidShares, pos.borrowShares);
        if (seizedAssets > 0) {
            uint256 seizedQuoted =
                Math.mulDiv(seizedAssets, collateralPrice, ConstantsLib.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
            repaidShares =
                seizedQuoted.wDivUp(incentiveFactor).toSharesUp(state.totalBorrowAssets, state.totalBorrowShares);
        } else {
            seizedAssets = Math.mulDiv(
                repaidShares.toAssetsDown(state.totalBorrowAssets, state.totalBorrowShares).wMulDown(incentiveFactor),
                ConstantsLib.ORACLE_PRICE_SCALE,
                collateralPrice
            );
        }
        repaidAssets = repaidShares.toAssetsUp(state.totalBorrowAssets, state.totalBorrowShares);

        require(repaidShares <= pos.borrowShares, RepaidSharesExceedDebt(repaidShares, pos.borrowShares));
        pos.borrowShares -= repaidShares.toUint128();
        state.totalBorrowShares -= repaidShares.toUint128();
        state.totalBorrowAssets = uint256(state.totalBorrowAssets).zeroFloorSub(repaidAssets).toUint128();
        require(seizedAssets <= pos.collateral, SeizedExceedsCollateral(seizedAssets, pos.collateral));
        pos.collateral -= seizedAssets.toUint128();
        (uint256 badDebtAssets, uint256 reserveUsed) = _realizeBadDebt(pos, state);
        _requireNoDust(pos, state, collateralPrice);
        _position[borrower] = pos;
        _marketState = state;

        emit EventsLib.Liquidate(
            msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, reserveUsed
        );

        return (seizedAssets, repaidAssets);
    }

    /// @dev 못 받게 된 빚 처리, 준비금으로 먼저 메우고 나머지는 예치 총액에서 차감
    function _realizeBadDebt(Position memory pos, MarketState memory state)
        internal
        pure
        returns (uint256 badDebtAssets, uint256 reserveUsed)
    {
        if (pos.collateral != 0 || pos.borrowShares == 0) return (0, 0);

        uint256 badDebtShares = pos.borrowShares;
        // 올림으로 총 차입을 넘지 않게 제한
        badDebtAssets = UtilsLib.min(
            state.totalBorrowAssets, badDebtShares.toAssetsUp(state.totalBorrowAssets, state.totalBorrowShares)
        );
        reserveUsed = UtilsLib.min(state.reserve, badDebtAssets);

        state.reserve -= reserveUsed.toUint128();
        state.totalSupplyAssets -= (badDebtAssets - reserveUsed).toUint128();
        state.totalBorrowAssets -= badDebtAssets.toUint128();
        state.totalBorrowShares -= badDebtShares.toUint128();
        pos.borrowShares = 0;
    }

    /// @dev 청산 뒤 빚이 남으면 남은 빚과 남은 담보 가치 모두 최소 부채 이상
    function _requireNoDust(Position memory pos, MarketState memory state, uint256 collateralPrice) internal view {
        if (pos.borrowShares == 0) return;

        uint256 debt = _debt(pos, state);
        require(debt >= MIN_DEBT, DebtBelowMinimum(debt, MIN_DEBT));

        uint256 collateralValue = Math.mulDiv(pos.collateral, collateralPrice, ConstantsLib.ORACLE_PRICE_SCALE);
        require(collateralValue >= MIN_DEBT, CollateralBelowMinimum(collateralValue, MIN_DEBT));
    }

    function _debt(Position memory pos, MarketState memory state) internal pure returns (uint256) {
        return uint256(pos.borrowShares).toAssetsUp(state.totalBorrowAssets, state.totalBorrowShares);
    }

    /// @dev 건강 여부, 빚이 없으면 가격 조회 없이 통과
    function _isHealthy(Position memory pos, MarketState memory state) internal view returns (bool) {
        if (pos.borrowShares == 0) return true;

        return _isHealthy(pos, state, ORACLE.price());
    }

    /// @dev 건강 여부, 빚이 담보 가치 × LLTV 이하
    function _isHealthy(Position memory pos, MarketState memory state, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        uint256 maxBorrow = Math.mulDiv(pos.collateral, collateralPrice, ConstantsLib.ORACLE_PRICE_SCALE).wMulDown(LLTV);

        return maxBorrow >= _debt(pos, state);
    }

    function _liquidity(MarketState memory state) internal pure returns (uint256) {
        return uint256(state.totalSupplyAssets).zeroFloorSub(state.totalBorrowAssets);
    }

    function _liquidationIncentiveFactor() internal view returns (uint256) {
        return UtilsLib.min(
            ConstantsLib.MAX_LIQUIDATION_INCENTIVE_FACTOR,
            WAD.wDivDown(WAD - ConstantsLib.LIQUIDATION_CURSOR.wMulDown(WAD - LLTV))
        );
    }
}
