// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 이동 때마다 상대 코드를 부르는 토큰
contract HookToken is ERC20 {
    address public hookTarget;

    constructor() ERC20("Hook Token", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHookTarget(address target) external {
        hookTarget = target;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && (from == hookTarget || to == hookTarget)) {
            IHookReceiver(hookTarget).onTokenTransfer(from, to, value);
        }
    }
}

interface IHookReceiver {
    function onTokenTransfer(address from, address to, uint256 value) external;
}
