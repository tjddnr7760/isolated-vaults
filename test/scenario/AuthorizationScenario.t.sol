// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMarket, Authorization, Signature} from "../../src/interfaces/IMarket.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {BaseTest} from "../BaseTest.sol";

/// @notice 서명으로 준 대리 권한의 사용과 회수 흐름
contract AuthorizationScenarioTest is BaseTest {
    uint256 internal constant SIGNER_KEY = 0xA11CE;

    address internal SIGNER;
    address internal OPERATOR = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        SIGNER = vm.addr(SIGNER_KEY);
        _deposit(SUPPLIER, 10_000e6);
        collateralToken.mint(SIGNER, 5e18);
        vm.startPrank(SIGNER);
        collateralToken.approve(address(market), type(uint256).max);
        market.supplyCollateral(5e18, SIGNER);
        vm.stopPrank();
    }

    function _sign(Authorization memory authorization) internal view returns (Signature memory signature) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            market.eip712Domain();
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (signature.v, signature.r, signature.s) = vm.sign(SIGNER_KEY, digest);
    }

    /// @dev 서명으로 권한 부여 → 대리 대출 → 권한 회수 → 대리 대출 재시도
    function test_Scenario_Operator_BorrowsOnlyWhileAuthorized() public {
        // given
        Authorization memory authorization = Authorization({
            authorizer: SIGNER,
            authorized: OPERATOR,
            isAuthorized: true,
            nonce: market.nonces(SIGNER),
            deadline: block.timestamp + 1 hours
        });
        Signature memory signature = _sign(authorization);
        vm.prank(OTHER);
        market.setAuthorizationWithSig(authorization, signature);
        vm.prank(OPERATOR);
        market.borrow(1_000e6, SIGNER, OPERATOR);
        // 빚은 서명자 포지션에, 빌린 돈은 대리인에게
        assertEq(market.debtOf(SIGNER), 1_000e6);
        assertEq(loanToken.balanceOf(OPERATOR), 1_000e6);

        // when
        vm.prank(SIGNER);
        market.setAuthorization(OPERATOR, false);

        // then
        vm.prank(OPERATOR);
        vm.expectRevert(IMarket.Unauthorized.selector);
        market.borrow(1_000e6, SIGNER, OPERATOR);
    }
}
