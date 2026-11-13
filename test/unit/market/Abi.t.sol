// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

contract AbiTest is Test {
    function _contains(string[] memory list, string memory item) internal pure returns (bool) {
        bytes32 hashed = keccak256(bytes(item));
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == hashed) return true;
        }
        return false;
    }

    /// @dev 빌드 결과의 abi 에서 함수 이름만 모음. 린트가 다시 써도 abi 는 남음
    function _functionNames() internal view returns (string[] memory names) {
        string memory json = vm.readFile("out/Market.sol/Market.json");
        uint256 total;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(total), "]"))) ++total;
        string[] memory found = new string[](total);
        uint256 count;
        for (uint256 i; i < total; ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type")))) != keccak256("function")) {
                continue;
            }
            found[count++] = vm.parseJsonString(json, string.concat(entry, ".name"));
        }
        names = new string[](count);
        for (uint256 i; i < count; ++i) {
            names[i] = found[i];
        }
    }

    function test_Abi_ExternalFunctionsMatchDesign() public view {
        // given
        string[] memory actual = _functionNames();

        // 상태를 바꾸는 함수
        string[16] memory changing = [
            "accrueInterest",
            "approve",
            "borrow",
            "deposit",
            "flashLoan",
            "liquidate",
            "mint",
            "redeem",
            "repay",
            "setAuthorization",
            "setAuthorizationWithSig",
            "supplyCollateral",
            "transfer",
            "transferFrom",
            "withdraw",
            "withdrawCollateral"
        ];
        // 읽기 전용 함수
        string[35] memory views = [
            "COLLATERAL_TOKEN",
            "IRM",
            "LLTV",
            "MIN_DEBT",
            "ORACLE",
            "RESERVE_FACTOR",
            "allowance",
            "asset",
            "balanceOf",
            "convertToAssets",
            "convertToShares",
            "debtOf",
            "decimals",
            "eip712Domain",
            "expectedMarketState",
            "isAuthorized",
            "isHealthy",
            "liquidationIncentiveFactor",
            "liquidity",
            "marketParams",
            "marketState",
            "maxDeposit",
            "maxMint",
            "maxRedeem",
            "maxWithdraw",
            "name",
            "nonces",
            "position",
            "previewDeposit",
            "previewMint",
            "previewRedeem",
            "previewWithdraw",
            "symbol",
            "totalAssets",
            "totalSupply"
        ];

        // when, then
        assertEq(actual.length, changing.length + views.length, "function count changed");
        for (uint256 i; i < changing.length; ++i) {
            assertTrue(_contains(actual, changing[i]), changing[i]);
        }
        for (uint256 i; i < views.length; ++i) {
            assertTrue(_contains(actual, views[i]), views[i]);
        }
    }
}
