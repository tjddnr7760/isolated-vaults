// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 테스트넷 전용 대출 토큰, 누구나 파우셋으로 받을 수 있음
/// @dev 실제 가치 없음. 메인넷 배포 금지
contract TestUSDC is ERC20 {
    /// @notice 파우셋 한 번에 받는 양 (1만 tUSDC)
    uint256 public constant FAUCET_AMOUNT = 10_000e6;

    /// @notice 같은 주소의 파우셋 재사용 대기 시간
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    /// @notice 주소별 마지막 파우셋 사용 시각
    mapping(address => uint256) public lastFaucetAt;

    /// @notice 대기 시간 안의 재사용
    error FaucetCooldown(uint256 availableAt);

    /// @param initialHolder 시장에 빌려줄 초기 물량을 받을 주소
    constructor(address initialHolder, uint256 initialAmount) ERC20("Test USD Coin", "tUSDC") {
        _mint(initialHolder, initialAmount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice 호출자에게 FAUCET_AMOUNT 지급
    function faucet() external {
        uint256 last = lastFaucetAt[msg.sender];
        // 처음 쓰는 주소는 0 이라 바로 통과
        if (last != 0) {
            require(block.timestamp >= last + FAUCET_COOLDOWN, FaucetCooldown(last + FAUCET_COOLDOWN));
        }

        lastFaucetAt[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
