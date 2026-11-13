// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {Market} from "../../../src/Market.sol";
import {IMarket, Authorization, Signature} from "../../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {BaseTest} from "../../BaseTest.sol";

contract AuthorizationTest is BaseTest {
    // secp256k1 곡선의 차수
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SIGNER_KEY = 0xA11CE;

    address internal SIGNER;
    address internal OPERATOR = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        SIGNER = vm.addr(SIGNER_KEY);
        _deposit(SUPPLIER, 10_000e6);
        _supplyCollateral(BORROWER, 5e18);
        collateralToken.mint(SIGNER, 5e18);
        vm.startPrank(SIGNER);
        collateralToken.approve(address(market), type(uint256).max);
        market.supplyCollateral(5e18, SIGNER);
        vm.stopPrank();
    }

    function _authorization(uint256 nonce, uint256 deadline, bool isAuthorized)
        internal
        view
        returns (Authorization memory)
    {
        return Authorization({
            authorizer: SIGNER, authorized: OPERATOR, isAuthorized: isAuthorized, nonce: nonce, deadline: deadline
        });
    }

    function _digest(Market target, Authorization memory authorization) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            target.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 structHash = keccak256(abi.encode(ConstantsLib.AUTHORIZATION_TYPEHASH, authorization));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 key, Market target, Authorization memory authorization)
        internal
        view
        returns (Signature memory signature)
    {
        (signature.v, signature.r, signature.s) = vm.sign(key, _digest(target, authorization));
    }

    /* setAuthorization */

    function test_SetAuthorization_Grants() public {
        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.SetAuthorization(BORROWER, BORROWER, OPERATOR, true);
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // then
        assertTrue(market.isAuthorized(BORROWER, OPERATOR));
        // 반대 방향 권한은 없음
        assertFalse(market.isAuthorized(OPERATOR, BORROWER));
    }

    function test_SetAuthorization_Revokes() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, false);

        // then
        assertFalse(market.isAuthorized(BORROWER, OPERATOR));
    }

    function test_SetAuthorization_RevertWhen_RevokingUnsetAuthorization() public {
        // when, then
        vm.prank(BORROWER);
        vm.expectRevert(IMarket.AlreadySet.selector);
        market.setAuthorization(OPERATOR, false);
    }

    function test_SetAuthorization_RevertWhen_GrantingTwice() public {
        // given
        vm.startPrank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when, then
        vm.expectRevert(IMarket.AlreadySet.selector);
        market.setAuthorization(OPERATOR, true);
        vm.stopPrank();
    }

    /* 대리인의 동작 */

    function test_Operator_CanBorrowOnBehalf() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when
        vm.prank(OPERATOR);
        market.borrow(1_000e6, BORROWER, RECEIVER);

        // then
        assertEq(market.debtOf(BORROWER), 1_000e6);
        assertEq(market.debtOf(OPERATOR), 0);
        assertEq(loanToken.balanceOf(RECEIVER), 1_000e6);
    }

    function test_Operator_CanWithdrawCollateralOnBehalf() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when
        vm.prank(OPERATOR);
        market.withdrawCollateral(1e18, BORROWER, RECEIVER);

        // then
        assertEq(market.position(BORROWER).collateral, 4e18);
        assertEq(collateralToken.balanceOf(RECEIVER), 1e18);
    }

    /// @dev 대리인에게도 건강 검사 적용
    function test_Operator_RevertWhen_BorrowMakesPositionUnhealthy() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when, then
        vm.prank(OPERATOR);
        vm.expectRevert(IMarket.Unhealthy.selector);
        market.borrow(8_600e6 + 1, BORROWER, OPERATOR);
    }

    /// @dev 대리인에게도 최소 부채 적용
    function test_Operator_RevertWhen_BorrowBelowMinDebt() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when, then
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IMarket.DebtBelowMinimum.selector, MIN_DEBT - 1, MIN_DEBT));
        market.borrow(MIN_DEBT - 1, BORROWER, OPERATOR);
    }

    /// @dev 권한은 준 사람의 포지션에만 적용
    function test_Operator_RevertWhen_WithdrawCollateralFromOtherAccount() public {
        // given
        vm.prank(BORROWER);
        market.setAuthorization(OPERATOR, true);

        // when, then
        vm.prank(OPERATOR);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.withdrawCollateral(1e18, SIGNER, OPERATOR);
    }

    /// @dev 권한을 거두면 대출 즉시 차단
    function test_Operator_RevertWhen_BorrowAfterRevoked() public {
        // given
        vm.startPrank(BORROWER);
        market.setAuthorization(OPERATOR, true);
        market.setAuthorization(OPERATOR, false);
        vm.stopPrank();

        // when, then
        vm.prank(OPERATOR);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.borrow(1_000e6, BORROWER, OPERATOR);
    }

    /// @dev 권한을 거두면 담보 인출 즉시 차단
    function test_Operator_RevertWhen_WithdrawCollateralAfterRevoked() public {
        // given
        vm.startPrank(BORROWER);
        market.setAuthorization(OPERATOR, true);
        market.setAuthorization(OPERATOR, false);
        vm.stopPrank();

        // when, then
        vm.prank(OPERATOR);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.withdrawCollateral(1e18, BORROWER, OPERATOR);
    }

    /* setAuthorizationWithSig */

    function test_SetAuthorizationWithSig_AnyoneCanSubmit() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);

        // when, then
        vm.expectEmit(address(market));
        emit EventsLib.SetAuthorization(OTHER, SIGNER, OPERATOR, true);
        vm.prank(OTHER);
        market.setAuthorizationWithSig(authorization, signature);

        // then
        assertTrue(market.isAuthorized(SIGNER, OPERATOR));
        assertEq(market.nonces(SIGNER), 1);
        // 제출자는 권한 없음
        assertFalse(market.isAuthorized(SIGNER, OTHER));
    }

    /// @dev 서명으로 받은 권한으로 대리인의 대출 가능
    function test_Operator_CanBorrowAfterAuthorizationWithSig() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        vm.prank(OTHER);
        market.setAuthorizationWithSig(authorization, signature);

        // when
        vm.prank(OPERATOR);
        market.borrow(1_000e6, SIGNER, OPERATOR);

        // then
        assertEq(market.debtOf(SIGNER), 1_000e6);
    }

    function test_SetAuthorizationWithSig_CanRevoke() public {
        // given
        Authorization memory grant = _authorization(0, block.timestamp + 1 hours, true);
        market.setAuthorizationWithSig(grant, _sign(SIGNER_KEY, market, grant));
        Authorization memory revoke = _authorization(1, block.timestamp + 1 hours, false);

        // when
        market.setAuthorizationWithSig(revoke, _sign(SIGNER_KEY, market, revoke));

        // then
        assertFalse(market.isAuthorized(SIGNER, OPERATOR));
        assertEq(market.nonces(SIGNER), 2);
    }

    function test_SetAuthorizationWithSig_RevertWhen_DeadlinePassed() public {
        // given
        uint256 deadline = block.timestamp + 1 hours;
        Authorization memory authorization = _authorization(0, deadline, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        vm.warp(deadline + 1);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(IMarket.SignatureExpired.selector, deadline));
        market.setAuthorizationWithSig(authorization, signature);
    }

    function test_SetAuthorizationWithSig_AcceptsAtDeadline() public {
        // given
        uint256 deadline = block.timestamp + 1 hours;
        Authorization memory authorization = _authorization(0, deadline, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        vm.warp(deadline);

        // when
        market.setAuthorizationWithSig(authorization, signature);

        // then
        assertTrue(market.isAuthorized(SIGNER, OPERATOR));
    }

    /// @dev 같은 서명 재사용과 거둔 권한 되살리기 거절
    function test_SetAuthorizationWithSig_RevertWhen_Replayed() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        market.setAuthorizationWithSig(authorization, signature);
        vm.prank(SIGNER);
        market.setAuthorization(OPERATOR, false);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, SIGNER, 1));
        market.setAuthorizationWithSig(authorization, signature);

        // then
        assertFalse(market.isAuthorized(SIGNER, OPERATOR));
    }

    function test_SetAuthorizationWithSig_RevertWhen_WrongNonce() public {
        // given
        Authorization memory authorization = _authorization(1, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);

        // when, then
        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, SIGNER, 0));
        market.setAuthorizationWithSig(authorization, signature);
    }

    function test_SetAuthorizationWithSig_RevertWhen_SignedByOther() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(0xB0B, market, authorization);

        // when, then
        vm.expectRevert(IMarket.InvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, signature);
    }

    function test_SetAuthorizationWithSig_RevertWhen_AuthorizedTampered() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        authorization.authorized = OTHER;

        // when, then
        vm.expectRevert(IMarket.InvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, signature);
    }

    function test_SetAuthorizationWithSig_RevertWhen_DeadlineTampered() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        authorization = _authorization(0, block.timestamp + 2 hours, true);

        // when, then
        vm.expectRevert(IMarket.InvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, signature);
    }

    function test_SetAuthorizationWithSig_RevertWhen_SignedForOtherMarket() public {
        // given
        Market otherMarket = new Market(params);
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, otherMarket, authorization);

        // when, then
        vm.expectRevert(IMarket.InvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, signature);
    }

    /// @dev 다른 시장용 서명은 그 시장에서만 통과
    function test_SetAuthorizationWithSig_AcceptedByMarketItWasSignedFor() public {
        // given
        Market otherMarket = new Market(params);
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, otherMarket, authorization);

        // when
        otherMarket.setAuthorizationWithSig(authorization, signature);

        // then
        assertTrue(otherMarket.isAuthorized(SIGNER, OPERATOR));
    }

    function test_SetAuthorizationWithSig_RevertWhen_ChainIdChanged() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);

        vm.chainId(block.chainid + 1);

        // when, then
        vm.expectRevert(IMarket.InvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, signature);
    }

    /// @dev s 를 뒤집은 서명 거절
    function test_SetAuthorizationWithSig_RevertWhen_MalleatedSignature() public {
        // given
        Authorization memory authorization = _authorization(0, block.timestamp + 1 hours, true);
        Signature memory signature = _sign(SIGNER_KEY, market, authorization);
        Signature memory twin =
            Signature({v: signature.v == 27 ? 28 : 27, r: signature.r, s: bytes32(SECP256K1_N - uint256(signature.s))});

        // when, then
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, twin.s));
        market.setAuthorizationWithSig(authorization, twin);
    }

    /// @dev 엉터리 서명으로 0 주소 권한 변경 불가
    function test_SetAuthorizationWithSig_RevertWhen_ZeroSigner() public {
        // given
        Authorization memory authorization = Authorization({
            authorizer: address(0), authorized: OPERATOR, isAuthorized: true, nonce: 0, deadline: block.timestamp
        });

        // when, then
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        market.setAuthorizationWithSig(authorization, Signature({v: 27, r: bytes32(0), s: bytes32(0)}));
    }

    function testFuzz_SetAuthorizationWithSig_OnlySignerKeyWorks(uint256 key, address authorized, bool isAuthorized)
        public
    {
        // given
        key = bound(key, 1, SECP256K1_N - 1);
        Authorization memory authorization = Authorization({
            authorizer: SIGNER, authorized: authorized, isAuthorized: isAuthorized, nonce: 0, deadline: block.timestamp
        });
        Signature memory signature = _sign(key, market, authorization);

        // when, then
        if (key == SIGNER_KEY) {
            market.setAuthorizationWithSig(authorization, signature);
            assertEq(market.isAuthorized(SIGNER, authorized), isAuthorized);
        } else {
            vm.expectRevert(IMarket.InvalidSignature.selector);
            market.setAuthorizationWithSig(authorization, signature);
        }
    }
}
