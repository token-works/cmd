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

    /// @notice The participant allocation is 50% of INITIAL_SUPPLY = 500_000_000 ether.
    ///         25% (250_000_000 ether) is unlocked immediately at launch.
    ///         25% (250_000_000 ether) vests linearly over 15 days.
    uint256 public constant PARTICIPANT_ALLOCATION = INITIAL_SUPPLY / 2; // 500M
    uint256 public constant IMMEDIATE_UNLOCK = PARTICIPANT_ALLOCATION / 2; // 250M
    uint256 public constant VESTING_AMOUNT = PARTICIPANT_ALLOCATION / 2;  // 250M
    uint256 public constant VESTING_DURATION = 15 days;

    /// @notice Address that manages the participant allocation (set once via setupVesting)
    address public vestingManager;

    /// @notice Timestamp when vesting begins
    uint256 public vestingStart;

    /// @notice Whether vesting has been set up
    bool public vestingSetup;

    /// @notice Total amount already claimed from the vesting portion
    uint256 public totalVestingClaimed;

    // COMMUNITY_LOGIC

    /// @notice Returns the total amount of vesting tokens that have become claimable so far
    function vestedAmount() public view returns (uint256) {
        if (!vestingSetup) return 0;
        if (block.timestamp >= vestingStart + VESTING_DURATION) {
            return VESTING_AMOUNT;
        }
        return (VESTING_AMOUNT * (block.timestamp - vestingStart)) / VESTING_DURATION;
    }

    /// @notice Returns the amount of vesting tokens currently available to claim
    function claimableVesting() public view returns (uint256) {
        uint256 vested = vestedAmount();
        if (vested <= totalVestingClaimed) return 0;
        return vested - totalVestingClaimed;
    }

    // COMMUNITY_FUNCTIONS

    /// @notice Called once by the deployer (msg.sender who holds INITIAL_SUPPLY) to set up the
    ///         participant allocation. Immediately transfers the 25% unlocked portion to a
    ///         designated participant address and locks the remaining 25% for linear vesting.
    /// @param participantAddress The address that receives the immediate unlock and vesting tokens
    function setupVesting(address participantAddress) external {
        require(!vestingSetup, "Vesting already setup");
        require(participantAddress != address(0), "Invalid participant address");

        vestingSetup = true;
        vestingManager = participantAddress;
        vestingStart = block.timestamp;

        // Transfer the immediately unlocked 25% to the participant address
        _transfer(msg.sender, participantAddress, IMMEDIATE_UNLOCK);

        // Transfer the vesting portion to this contract to hold in escrow
        _transfer(msg.sender, address(this), VESTING_AMOUNT);
    }

    /// @notice Allows the vesting manager to claim vested tokens that have become available
    function claimVested() external {
        require(vestingSetup, "Vesting not setup");
        require(msg.sender == vestingManager, "Not vesting manager");

        uint256 amount = claimableVesting();
        require(amount > 0, "Nothing to claim");

        totalVestingClaimed += amount;
        _transfer(address(this), vestingManager, amount);
    }
}