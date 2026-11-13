// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {CollateralConfig, DeployBase, DeployConfig, Deployment} from "./DeployBase.sol";

/// @notice Sepolia 배포. tUSDC 를 빌려주는 WETH 시장과 LINK 시장
/// @dev 키는 파일이나 환경 변수에 두지 않고 forge 키스토어(--account)로 서명
contract Deploy is Script, DeployBase {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    function run() external returns (Deployment memory d) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address owner = msg.sender;

        vm.startBroadcast(owner);
        d = _deploy(sepoliaConfig(), owner);
        vm.stopBroadcast();

        _writeAddresses(d);
    }

    /// @notice Sepolia 의 실제 토큰과 Chainlink 피드
    function sepoliaConfig() public pure returns (DeployConfig memory) {
        return DeployConfig({
            weth: CollateralConfig({
                token: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
                lltv: 0.86e18
            }),
            link: CollateralConfig({
                token: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
                feed: 0xc59E3633BAAC79493d908e63626716e204A45EdF, // LINK / USD
                lltv: 0.77e18
            }),
            // 피드 갱신 주기 약 1시간
            maxStaleness: 4500,
            initialSupply: 1_000_000e6,
            seedPerMarket: 100_000e6
        });
    }

    function _writeAddresses(Deployment memory d) internal {
        string memory key = "deployment";
        vm.serializeAddress(key, "loanToken", address(d.loanToken));
        vm.serializeAddress(key, "irm", address(d.irm));
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "wethOracle", address(d.wethOracle));
        vm.serializeAddress(key, "linkOracle", address(d.linkOracle));
        vm.serializeAddress(key, "wethMarket", address(d.wethMarket));
        string memory json = vm.serializeAddress(key, "linkMarket", address(d.linkMarket));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
