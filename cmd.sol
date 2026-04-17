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
    address public hook;
    address public owner;

    error NotAuthorized();
    error HookAlreadySet();
    error ZeroAddress();

    // COMMUNITY_LOGIC
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotAuthorized();
        _;
    }

    // COMMUNITY_FUNCTIONS
    function setHook(address _hook) external onlyOwner {
        if (_hook == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
    }

    function burnFromHook(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
    }

    function mintOwner(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}