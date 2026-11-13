// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {MarketParams} from "../src/interfaces/IMarket.sol";

/// @notice 추가 담보마다 시장을 하나씩 만들고 첫 예치
/// @dev 누구나 만들 수 있지만 첫 예치 tUSDC 가 owner 에게 있어 owner 가 실행
contract CreateMarkets is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant MIN_DEBT = 200e6;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;
    uint256 internal constant SEED = 50_000e6;

    struct Pick {
        string symbol;
        uint256 lltv;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        string memory chain = vm.toString(block.chainid);
        string memory base = vm.readFile(string.concat("deployments/", chain, ".json"));
        string memory col = vm.readFile(string.concat("deployments/", chain, "-collaterals.json"));
        MarketFactory factory = MarketFactory(vm.parseJsonAddress(base, ".factory"));
        address loanToken = vm.parseJsonAddress(base, ".loanToken");
        address irm = vm.parseJsonAddress(base, ".irm");

        Pick[] memory picks = sepoliaPicks();
        string memory out = "markets";
        string memory written;

        vm.startBroadcast();
        // 스크립트 안의 msg.sender 는 서명 지갑이 아닐 수 있어 실제 서명자를 읽음
        (, address me,) = vm.readCallers();
        for (uint256 i; i < picks.length; ++i) {
            string memory key = string.concat(".", picks[i].symbol);
            MarketParams memory p = MarketParams({
                loanToken: loanToken,
                collateralToken: vm.parseJsonAddress(col, string.concat(key, ".token")),
                oracle: vm.parseJsonAddress(col, string.concat(key, ".oracle")),
                irm: irm,
                lltv: picks[i].lltv,
                minDebt: MIN_DEBT,
                reserveFactor: RESERVE_FACTOR
            });
            address market = factory.computeMarketAddress(p);
            // 다시 실행해도 이미 있는 시장은 건너뜀
            if (!factory.isMarket(market)) {
                factory.createMarket(p);
                IERC20(loanToken).approve(market, SEED);
                Market(market).deposit(SEED, me);
            }
            written = vm.serializeAddress(out, picks[i].symbol, market);
        }
        vm.stopBroadcast();

        vm.writeJson(written, string.concat("deployments/", chain, "-markets.json"));
    }

    /// @notice 변동성에 맞춘 한도. 안정 자산 91.5%, 주요 자산 86%, 변동 큰 자산 77%, 주말에
    /// 멈추는 주식 62.5%
    function sepoliaPicks() public pure returns (Pick[] memory p) {
        p = new Pick[](12);
        p[0] = Pick("tWBTC", 0.86e18);
        p[1] = Pick("tWSTETH", 0.86e18);
        p[2] = Pick("tDAI", 0.915e18);
        p[3] = Pick("tEUR", 0.915e18);
        p[4] = Pick("tGBP", 0.915e18);
        p[5] = Pick("tJPY", 0.86e18);
        p[6] = Pick("tXAU", 0.77e18);
        p[7] = Pick("tCSPX", 0.625e18);
        p[8] = Pick("tIB01", 0.915e18);
        p[9] = Pick("tIBTA", 0.86e18);
        p[10] = Pick("tUSTB", 0.915e18);
        p[11] = Pick("tWTGXX", 0.915e18);
    }
}
