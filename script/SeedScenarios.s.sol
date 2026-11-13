// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Market} from "../src/Market.sol";
import {TestToken} from "./testnet/TestToken.sol";

/// @notice 새 주소로 파우셋을 한 번 받아 넘겨줌. 파우셋 대기 시간은 주소마다라 여러 번
/// 받을 때 씀
contract FaucetTap {
    constructor(TestToken token, address to) {
        token.faucet();
        IERC20(address(token)).transfer(to, token.FAUCET_AMOUNT());
    }
}

/// @notice 시연용 대출 상태. 담보를 받아 맡기고 빌려 시장마다 이용률을 다르게 만듦
/// @dev owner 키스토어로 실행. 대출자는 서명 지갑
contract SeedScenarios is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    struct Plan {
        string symbol;
        // 받을 파우셋 횟수. 담보 양
        uint256 taps;
        // 빌릴 tUSDC
        uint256 borrow;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        string memory chain = vm.toString(block.chainid);
        string memory col = vm.readFile(string.concat("deployments/", chain, "-collaterals.json"));
        string memory mk = vm.readFile(string.concat("deployments/", chain, "-markets.json"));

        Plan[] memory plans = sepoliaPlans();
        vm.startBroadcast();
        // 스크립트 안의 msg.sender 는 서명 지갑이 아닐 수 있어 실제 서명자를 읽음
        (VmSafe.CallerMode mode, address me,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "broadcast only");

        for (uint256 i; i < plans.length; ++i) {
            Plan memory p = plans[i];
            TestToken token = TestToken(vm.parseJsonAddress(col, string.concat(".", p.symbol, ".token")));
            Market market = Market(vm.parseJsonAddress(mk, string.concat(".", p.symbol)));

            for (uint256 k; k < p.taps; ++k) {
                new FaucetTap(token, me);
            }
            uint256 amount = p.taps * token.FAUCET_AMOUNT();
            IERC20(address(token)).approve(address(market), amount);
            market.supplyCollateral(amount, me);
            market.borrow(p.borrow, me, me);
        }
        vm.stopBroadcast();
    }

    /// @notice 시장마다 예치금 50,000 tUSDC. 빌리는 양으로 이용률을 정함
    function sepoliaPlans() public pure returns (Plan[] memory p) {
        p = new Plan[](10);
        // 낮은 이용률
        p[0] = Plan("tIBTA", 1, 2_000e6);
        p[1] = Plan("tWBTC", 1, 4_000e6);
        p[2] = Plan("tXAU", 1, 6_000e6);
        // 한도에 가깝게 빌린 시장
        p[3] = Plan("tWTGXX", 1, 9_000e6);
        // 중간 이용률
        p[4] = Plan("tJPY", 4, 25_000e6);
        p[5] = Plan("tCSPX", 6, 30_000e6);
        p[6] = Plan("tIB01", 5, 35_000e6);
        p[7] = Plan("tDAI", 5, 37_000e6);
        // 금리 급등선 바로 아래와 위
        p[8] = Plan("tEUR", 6, 44_500e6);
        p[9] = Plan("tGBP", 6, 47_000e6);
    }
}
