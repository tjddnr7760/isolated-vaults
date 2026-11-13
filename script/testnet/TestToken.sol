// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 테스트넷 전용 담보 토큰, 누구나 하루 한 번 받을 수 있음
/// @dev 실제 가치 없음. 메인넷 배포 금지
contract TestToken is ERC20 {
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    uint8 private immutable DECIMALS;

    /// @notice 파우셋 한 번에 받는 양
    uint256 public immutable FAUCET_AMOUNT;

    mapping(address => uint256) public lastFaucetAt;

    error FaucetCooldown(uint256 availableAt);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount)
        ERC20(name_, symbol_)
    {
        DECIMALS = decimals_;
        FAUCET_AMOUNT = faucetAmount;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

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
