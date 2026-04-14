// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CMD is ERC20 {
    // @locked-start CORE_SUPPLY_CONSTANT
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    // @locked-end CORE_SUPPLY_CONSTANT

    // @locked-start TOKEN_METADATA
    string private constant TOKEN_NAME = "TenCommandments";
    string private constant TOKEN_SYMBOL = "CMD";
    // @locked-end TOKEN_METADATA

    // @locked-start CORE_CONSTRUCTOR
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    // @locked-end CORE_CONSTRUCTOR

    // @locked-start CORE_ERC20_SURFACE
    function transfer(address to, uint256 value) public override returns (bool) {
        return super.transfer(to, value);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        return super.transferFrom(from, to, value);
    }
    // @locked-end CORE_ERC20_SURFACE

    // @locked-start CORE_TOTAL_SUPPLY
    function totalSupply() public view override returns (uint256) {
        return super.totalSupply();
    }
    // @locked-end CORE_TOTAL_SUPPLY

    // COMMUNITY_STATE

    /// @notice Total tokens permanently locked as liquidity from sell fees
    uint256 public totalPermanentlyLockedLiquidity;

    // COMMUNITY_LOGIC

    // COMMUNITY_FUNCTIONS

    /// @notice Returns the amount of tokens permanently locked for liquidity
    function getPermanentlyLockedLiquidity() external view returns (uint256) {
        return totalPermanentlyLockedLiquidity;
    }

    /// @notice Called by the hook to record permanently locked liquidity
    /// @param amount The amount of tokens locked
    function recordLockedLiquidity(uint256 amount) external {
        totalPermanentlyLockedLiquidity += amount;
    }
}