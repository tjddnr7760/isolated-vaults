// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KinkedRateModel} from "../src/KinkedRateModel.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MarketParams} from "../src/interfaces/IMarket.sol";
import {TestUSDC} from "./testnet/TestUSDC.sol";

/// @notice 담보 하나의 시장 설정
struct CollateralConfig {
    address token;
    address feed;
    // 청산 기준 담보 비율 (WAD)
    uint256 lltv;
}

struct DeployConfig {
    CollateralConfig weth;
    CollateralConfig link;
    // 가격 허용 시간 (초)
    uint256 maxStaleness;
    // 배포자가 받는 tUSDC 초기 물량
    uint256 initialSupply;
    // 시장마다 처음 예치할 tUSDC
    uint256 seedPerMarket;
}

struct Deployment {
    TestUSDC loanToken;
    KinkedRateModel irm;
    MarketFactory factory;
    OracleAdapter wethOracle;
    OracleAdapter linkOracle;
    Market wethMarket;
    Market linkMarket;
}

/// @notice 배포 순서. 스크립트와 포크 테스트가 같이 씀
/// @dev 모든 호출은 owner 가 보낸다고 가정. 스크립트는 broadcast, 테스트는 prank 로 맞춤
abstract contract DeployBase {
    // 금리 곡선: 최적 이용률 90%, 기본 0%, 최적까지 연 4%, 이후 연 60%
    uint256 internal constant OPTIMAL_UTILIZATION = 0.9e18;
    uint256 internal constant BASE_RATE = 0;
    uint256 internal constant SLOPE_1 = uint256(0.04e18) / 365 days;
    uint256 internal constant SLOPE_2 = uint256(0.6e18) / 365 days;

    uint256 internal constant MIN_DEBT = 200e6;
    uint256 internal constant RESERVE_FACTOR = 0.1e18;

    // 피드에서 하한과 상한을 읽지 못할 때 쓸 값 (8자리 달러)
    int256 internal constant FALLBACK_MIN_ANSWER = 1e6;
    int256 internal constant FALLBACK_MAX_ANSWER = 1_000_000e8;

    function _deploy(DeployConfig memory c, address owner) internal returns (Deployment memory d) {
        d.loanToken = new TestUSDC(owner, c.initialSupply);
        d.irm = new KinkedRateModel(OPTIMAL_UTILIZATION, BASE_RATE, SLOPE_1, SLOPE_2);
        d.factory = new MarketFactory(owner);
        d.wethOracle = _oracle(c.weth, address(d.loanToken), c.maxStaleness);
        d.linkOracle = _oracle(c.link, address(d.loanToken), c.maxStaleness);

        d.factory.enableIrm(address(d.irm));
        d.factory.enableLltv(c.weth.lltv);
        // 같은 LLTV 를 두 번 승인하면 revert
        if (c.link.lltv != c.weth.lltv) d.factory.enableLltv(c.link.lltv);
        d.factory.enableOracle(address(d.wethOracle));
        d.factory.enableOracle(address(d.linkOracle));

        d.wethMarket = _market(d, c.weth, address(d.wethOracle));
        d.linkMarket = _market(d, c.link, address(d.linkOracle));

        _seed(d.loanToken, d.wethMarket, c.seedPerMarket, owner);
        _seed(d.loanToken, d.linkMarket, c.seedPerMarket, owner);
    }

    function _oracle(CollateralConfig memory c, address loanToken, uint256 maxStaleness)
        internal
        returns (OracleAdapter)
    {
        return new OracleAdapter(c.feed, loanToken, c.token, maxStaleness, FALLBACK_MIN_ANSWER, FALLBACK_MAX_ANSWER);
    }

    function _market(Deployment memory d, CollateralConfig memory c, address oracle) internal returns (Market) {
        MarketParams memory p = MarketParams({
            loanToken: address(d.loanToken),
            collateralToken: c.token,
            oracle: oracle,
            irm: address(d.irm),
            lltv: c.lltv,
            minDebt: MIN_DEBT,
            reserveFactor: RESERVE_FACTOR
        });
        return Market(d.factory.createMarket(p));
    }

    function _seed(TestUSDC loanToken, Market market, uint256 assets, address owner) internal {
        IERC20(address(loanToken)).approve(address(market), assets);
        market.deposit(assets, owner);
    }
}
