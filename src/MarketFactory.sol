// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {WAD} from "morpho-blue/libraries/MathLib.sol";

import {Market} from "./Market.sol";
import {MarketParams} from "./interfaces/IMarket.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice 승인된 값으로 시장을 만드는 팩토리
contract MarketFactory is IMarketFactory, Ownable2Step {
    /* STORAGE */

    mapping(uint256 => bool) public isLltvEnabled;

    mapping(address => bool) public isIrmEnabled;

    mapping(address => bool) public isOracleEnabled;

    mapping(address => bool) public isMarket;

    /* CONSTRUCTOR */

    constructor(address initialOwner) Ownable(initialOwner) {}

    /* ONLY OWNER FUNCTIONS */

    function enableLltv(uint256 lltv) external onlyOwner {
        require(!isLltvEnabled[lltv], AlreadyEnabled());
        require(lltv < WAD, LltvTooHigh(lltv));

        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    function enableIrm(address irm) external onlyOwner {
        require(!isIrmEnabled[irm], AlreadyEnabled());
        require(irm.code.length != 0, NoCode(irm));

        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    function enableOracle(address oracle) external onlyOwner {
        require(!isOracleEnabled[oracle], AlreadyEnabled());
        require(oracle.code.length != 0, NoCode(oracle));

        isOracleEnabled[oracle] = true;

        emit EventsLib.EnableOracle(oracle);
    }

    /* MARKET CREATION */

    function createMarket(MarketParams memory p) external returns (address market) {
        require(isLltvEnabled[p.lltv], LltvNotEnabled(p.lltv));
        require(isIrmEnabled[p.irm], IrmNotEnabled(p.irm));
        require(isOracleEnabled[p.oracle], OracleNotEnabled(p.oracle));
        require(
            IOracle(p.oracle).LOAN_TOKEN() == p.loanToken && IOracle(p.oracle).COLLATERAL_TOKEN() == p.collateralToken,
            OracleTokenMismatch(p.oracle)
        );
        address expected = computeMarketAddress(p);
        require(!isMarket[expected], MarketAlreadyCreated(expected));

        isMarket[expected] = true;

        emit EventsLib.CreateMarket(expected, msg.sender, p);

        market = address(new Market{salt: _salt(p)}(p));
    }

    /* VIEW */

    function computeMarketAddress(MarketParams memory p) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(Market).creationCode, abi.encode(p)));

        return Create2.computeAddress(_salt(p), initCodeHash);
    }

    /* INTERNAL */

    /// @dev 파라미터의 해시
    function _salt(MarketParams memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }
}
