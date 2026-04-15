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
    uint256 public constant TAX_BIPS = 9000;
    uint256 public constant BIPS_DENOMINATOR = 10000;
    uint256 public constant PUZZLE_COUNT = 67999;
    uint256 public constant PUZZLE_TIMEOUT = 240 hours;
    uint256 public constant BUYBACK_CALLER_BOUNTY_BIPS = 100;

    address public admin;
    address public oracle;

    uint256 public nextRecordId;
    uint256 public forfeitedPool;

    struct TaxRecord {
        address sender;
        address recipient;
        uint256 grossAmount;
        uint256 taxAmount;
        uint256 timestamp;
        uint256 difficulty;
        bool refunded;
        bool expired;
    }

    mapping(uint256 => TaxRecord) public taxRecords;

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TaxRecorded(
        uint256 indexed recordId,
        address indexed sender,
        address indexed recipient,
        uint256 grossAmount,
        uint256 taxAmount,
        uint256 netAmount,
        uint256 difficulty,
        uint256 puzzleCount
    );
    event TaxRefunded(uint256 indexed recordId, address indexed sender, uint256 taxAmount);
    event TaxExpired(uint256 indexed recordId, uint256 taxAmount);
    event BuybackExecuted(address indexed caller, uint256 bountyAmount, uint256 burnAmount, uint256 remainingForfeitedPool);

    error NotAdmin();
    error NotOracle();
    error InvalidOracle();
    error InvalidRecord();
    error AlreadyRefunded();
    error AlreadyExpired();
    error RefundTooEarlyForExpiredRecord();
    error RecordNotExpired();
    error NoForfeitedPool();

    // COMMUNITY_LOGIC
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotOracle();
        _;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._transfer(from, to, value);
            return;
        }

        uint256 taxAmount = (value * TAX_BIPS) / BIPS_DENOMINATOR;
        uint256 netAmount = value - taxAmount;

        if (taxAmount > 0) {
            super._transfer(from, address(this), taxAmount);
        }

        if (netAmount > 0) {
            super._transfer(from, to, netAmount);
        }

        uint256 recordId = ++nextRecordId;
        uint256 difficulty = _difficultyForAmount(value);
        taxRecords[recordId] = TaxRecord({
            sender: from,
            recipient: to,
            grossAmount: value,
            taxAmount: taxAmount,
            timestamp: block.timestamp,
            difficulty: difficulty,
            refunded: false,
            expired: false
        });

        emit TaxRecorded(recordId, from, to, value, taxAmount, netAmount, difficulty, PUZZLE_COUNT);
    }

    function _difficultyForAmount(uint256 amount) internal pure returns (uint256) {
        return PUZZLE_COUNT + (amount / 1 ether);
    }

    // COMMUNITY_FUNCTIONS
    function setOracle(address newOracle) external onlyAdmin {
        if (newOracle == address(0)) revert InvalidOracle();
        address previousOracle = oracle;
        oracle = newOracle;
        emit OracleUpdated(previousOracle, newOracle);
    }

    function refundTax(uint256 recordId) external onlyOracle {
        TaxRecord storage record = taxRecords[recordId];
        if (record.sender == address(0)) revert InvalidRecord();
        if (record.refunded) revert AlreadyRefunded();
        if (record.expired) revert AlreadyExpired();

        record.refunded = true;
        super._transfer(address(this), record.sender, record.taxAmount);

        emit TaxRefunded(recordId, record.sender, record.taxAmount);
    }

    function expireRecord(uint256 recordId) public {
        TaxRecord storage record = taxRecords[recordId];
        if (record.sender == address(0)) revert InvalidRecord();
        if (record.refunded) revert AlreadyRefunded();
        if (record.expired) revert AlreadyExpired();
        if (block.timestamp < record.timestamp + PUZZLE_TIMEOUT) revert RecordNotExpired();

        record.expired = true;
        forfeitedPool += record.taxAmount;

        emit TaxExpired(recordId, record.taxAmount);
    }

    function expireRecords(uint256[] calldata recordIds) external {
        uint256 length = recordIds.length;
        for (uint256 i = 0; i < length; ++i) {
            expireRecord(recordIds[i]);
        }
    }

    function executeBuyback() external returns (uint256 bountyAmount, uint256 burnAmount) {
        uint256 poolAmount = forfeitedPool;
        if (poolAmount == 0) revert NoForfeitedPool();

        bountyAmount = (poolAmount * BUYBACK_CALLER_BOUNTY_BIPS) / BIPS_DENOMINATOR;
        burnAmount = poolAmount - bountyAmount;

        forfeitedPool = 0;

        if (bountyAmount > 0) {
            super._transfer(address(this), msg.sender, bountyAmount);
        }

        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
        }

        emit BuybackExecuted(msg.sender, bountyAmount, burnAmount, forfeitedPool);
    }

    function getTaxRecord(uint256 recordId) external view returns (TaxRecord memory) {
        return taxRecords[recordId];
    }

    function taxRecordStatus(uint256 recordId) external view returns (bool refundable, bool expirable, bool isRefunded, bool isExpired) {
        TaxRecord storage record = taxRecords[recordId];
        if (record.sender == address(0)) {
            return (false, false, false, false);
        }

        isRefunded = record.refunded;
        isExpired = record.expired;
        refundable = !isRefunded && !isExpired;
        expirable = !isRefunded && !isExpired && block.timestamp >= record.timestamp + PUZZLE_TIMEOUT;
    }
}