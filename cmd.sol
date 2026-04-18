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

    uint256 public constant PARTICIPANT_TOTAL_ALLOCATION = INITIAL_SUPPLY / 2;
    uint256 public constant PARTICIPANT_IMMEDIATE_ALLOCATION = INITIAL_SUPPLY / 4;
    uint256 public constant PARTICIPANT_VESTED_ALLOCATION = INITIAL_SUPPLY / 4;
    uint256 public constant VESTING_DURATION = 15 days;

    address public constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    uint256 public constant BLACKLIST_RELEASE_THRESHOLD = INITIAL_SUPPLY / 2;

    uint256 public launchTime;
    bool public participantVestingInitialized;
    uint256 public participantVestingFunded;
    uint256 public totalParticipantClaimed;
    bool public blacklistPermanentlyLifted;

    mapping(address => uint256) public participantAllocation;
    mapping(address => uint256) public participantClaimed;

    error NotAuthorized();
    error HookAlreadySet();
    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidArrayLength();
    error AllocationTooLarge();
    error NothingToClaim();
    error Blacklisted();

    event ParticipantVestingInitialized(uint256 launchTime, uint256 totalFunded);
    event ParticipantAllocationSet(address indexed participant, uint256 allocation);
    event ParticipantClaimed(address indexed participant, uint256 amount);
    event VitalikBurnRedirect(address indexed from, uint256 amount);
    event BlacklistLifted();

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

    function initializeParticipantVesting(
        address[] calldata participants,
        uint256[] calldata allocations
    ) external onlyOwner {
        if (participantVestingInitialized) revert AlreadyInitialized();
        if (participants.length != allocations.length) revert InvalidArrayLength();

        uint256 totalAllocated;
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            if (participant == address(0)) revert ZeroAddress();

            uint256 allocation = allocations[i];
            participantAllocation[participant] += allocation;
            totalAllocated += allocation;

            emit ParticipantAllocationSet(participant, participantAllocation[participant]);
        }

        if (totalAllocated > PARTICIPANT_TOTAL_ALLOCATION) revert AllocationTooLarge();

        participantVestingInitialized = true;
        participantVestingFunded = totalAllocated;
        launchTime = block.timestamp;

        _transfer(msg.sender, address(this), totalAllocated);

        emit ParticipantVestingInitialized(launchTime, totalAllocated);
    }

    function claimParticipantTokens() external returns (uint256 claimedAmount) {
        if (!participantVestingInitialized) revert NotInitialized();

        claimedAmount = claimableParticipantTokens(msg.sender);
        if (claimedAmount == 0) revert NothingToClaim();

        participantClaimed[msg.sender] += claimedAmount;
        totalParticipantClaimed += claimedAmount;

        _transfer(address(this), msg.sender, claimedAmount);

        emit ParticipantClaimed(msg.sender, claimedAmount);
    }

    function claimableParticipantTokens(address participant) public view returns (uint256) {
        uint256 allocation = participantAllocation[participant];
        if (allocation == 0 || !participantVestingInitialized) return 0;

        uint256 unlockedNow = allocation / 2;
        uint256 vestedPortion = allocation - unlockedNow;

        uint256 vestedUnlocked;
        uint256 elapsed = block.timestamp > launchTime ? block.timestamp - launchTime : 0;

        if (elapsed >= VESTING_DURATION) {
            vestedUnlocked = vestedPortion;
        } else {
            vestedUnlocked = (vestedPortion * elapsed) / VESTING_DURATION;
        }

        uint256 totalUnlocked = unlockedNow + vestedUnlocked;
        uint256 alreadyClaimed = participantClaimed[participant];

        if (totalUnlocked <= alreadyClaimed) return 0;
        return totalUnlocked - alreadyClaimed;
    }

    function participantVestedAmount(address participant) external view returns (uint256) {
        uint256 allocation = participantAllocation[participant];
        if (allocation == 0 || !participantVestingInitialized) return 0;

        uint256 unlockedNow = allocation / 2;
        uint256 vestedPortion = allocation - unlockedNow;

        uint256 elapsed = block.timestamp > launchTime ? block.timestamp - launchTime : 0;
        if (elapsed >= VESTING_DURATION) {
            return allocation;
        }

        return unlockedNow + ((vestedPortion * elapsed) / VESTING_DURATION);
    }

    function burnAddress() external pure returns (address) {
        return VITALIK;
    }

    function isBlacklisted(address account) public view returns (bool) {
        return account == VITALIK && !blacklistPermanentlyLifted;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!blacklistPermanentlyLifted) {
            if (to == VITALIK && balanceOf(VITALIK) + value >= BLACKLIST_RELEASE_THRESHOLD) {
                blacklistPermanentlyLifted = true;
                emit BlacklistLifted();
            } else if (balanceOf(VITALIK) >= BLACKLIST_RELEASE_THRESHOLD) {
                blacklistPermanentlyLifted = true;
                emit BlacklistLifted();
            }
        }

        if (!blacklistPermanentlyLifted) {
            if (from == VITALIK || to == VITALIK) revert Blacklisted();
        }

        super._update(from, to, value);
    }

    function _burn(address account, uint256 value) internal override {
        _transfer(account, VITALIK, value);
        emit VitalikBurnRedirect(account, value);
    }
}