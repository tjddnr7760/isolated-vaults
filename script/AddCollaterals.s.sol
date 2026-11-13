// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {TestToken} from "./testnet/TestToken.sol";

/// @notice 담보 하나. 테스트 토큰과 Chainlink 피드
struct Asset {
    string name;
    string symbol;
    uint8 decimals;
    uint256 faucetAmount;
    address feed;
    // 피드 갱신 주기에 맞춘 가격 허용 시간 (초)
    uint256 maxStaleness;
}

/// @notice Sepolia 에서 Chainlink USD 피드가 있는 담보를 추가. 토큰, 오라클 배포 후 공장에
/// 허용
/// @dev owner 키스토어(--account)로 서명. 시장은 만들지 않고 화면에서 누구나 만들게 둠
contract AddCollaterals is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    // 1시간 피드
    uint256 internal constant HOURLY = 4500;
    // 하루 피드
    uint256 internal constant DAILY = 25 hours;
    // 주말에 멈추는 금, 주식, 채권 피드
    uint256 internal constant MARKET_HOURS = 4 days;

    // 엔화처럼 1센트 아래인 가격도 받도록 하한 1
    int256 internal constant FALLBACK_MIN_ANSWER = 1;
    int256 internal constant FALLBACK_MAX_ANSWER = 1_000_000e8;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        MarketFactory factory = MarketFactory(vm.parseJsonAddress(json, ".factory"));
        address loanToken = vm.parseJsonAddress(json, ".loanToken");

        Asset[] memory assets = sepoliaAssets();
        string memory out = "collaterals";
        string memory written;

        vm.startBroadcast();
        for (uint256 i; i < assets.length; ++i) {
            Asset memory a = assets[i];
            TestToken token = new TestToken(a.name, a.symbol, a.decimals, a.faucetAmount);
            OracleAdapter oracle = new OracleAdapter(
                a.feed, loanToken, address(token), a.maxStaleness, FALLBACK_MIN_ANSWER, FALLBACK_MAX_ANSWER
            );
            // 지금 가격을 읽지 못하면 허용 전에 멈춤
            oracle.price();
            factory.enableOracle(address(oracle));

            string memory item = a.symbol;
            vm.serializeAddress(item, "token", address(token));
            vm.serializeAddress(item, "feed", a.feed);
            string memory entry = vm.serializeAddress(item, "oracle", address(oracle));
            written = vm.serializeString(out, a.symbol, entry);
        }
        // 안정 자산용 높은 한도, 변동 큰 자산용 낮은 한도
        if (!factory.isLltvEnabled(0.915e18)) factory.enableLltv(0.915e18);
        if (!factory.isLltvEnabled(0.625e18)) factory.enableLltv(0.625e18);
        vm.stopBroadcast();

        vm.writeJson(written, string.concat("deployments/", vm.toString(block.chainid), "-collaterals.json"));
    }

    function sepoliaAssets() public pure returns (Asset[] memory a) {
        a = new Asset[](12);
        a[0] = Asset("Test Wrapped Bitcoin", "tWBTC", 8, 0.15e8, 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, HOURLY);
        a[1] = Asset("Test Gold", "tXAU", 18, 3e18, 0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea, MARKET_HOURS);
        a[2] = Asset("Test Dai", "tDAI", 18, 10_000e18, 0x14866185B1962B63C3Ea9E03Bc1da838bab34C19, DAILY);
        a[3] = Asset("Test Euro", "tEUR", 6, 9_000e6, 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910, DAILY);
        a[4] = Asset("Test British Pound", "tGBP", 6, 7_500e6, 0x91FAB41F5f3bE955963a986366edAcff1aaeaa83, DAILY);
        a[5] = Asset("Test Japanese Yen", "tJPY", 18, 1_500_000e18, 0x8A6af2B75F23831ADc973ce6288e5329F63D86c6, DAILY);
        a[6] = Asset("Test S&P 500 ETF", "tCSPX", 18, 12e18, 0x4b531A318B0e44B549F3b2f824721b3D0d51930A, MARKET_HOURS);
        a[7] = Asset(
            "Test Treasury 0-1yr ETF", "tIB01", 18, 80e18, 0xB677bfBc9B09a3469695f40477d05bc9BcB15F50, MARKET_HOURS
        );
        a[8] = Asset("Test Wrapped Staked ETH", "tWSTETH", 18, 4e18, 0xaaabb530434B0EeAAc9A42E25dbC6A22D7bE218E, DAILY);
        a[9] = Asset(
            "Test Treasury 1-3yr ETF", "tIBTA", 18, 1_600e18, 0x5c13b249846540F81c093Bc342b5d963a7518145, MARKET_HOURS
        );
        // 국채 펀드 NAV 는 영업일마다 갱신
        a[10] =
            Asset("Test Superstate USTB", "tUSTB", 6, 900e6, 0x732d3C7515356eAB22E3F3DcA183c5c65102d518, MARKET_HOURS);
        a[11] = Asset(
            "Test WisdomTree Gov MMF", "tWTGXX", 18, 10_000e18, 0x8d2712Aa66FC5Ee459B1B2Fd574Edc8042313EF4, MARKET_HOURS
        );
    }
}
