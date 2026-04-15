// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CMDHook - Uniswap V4 Hook with Decreasing Fee Structure
/// @notice Manages fee collection for a single Uniswap V4 pool with a block-decaying buy fee
/// @dev Only the owner can initialize the pool. Buy fees decrease from 99% to 1% at 1% per block.
contract CMDHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    /* ═══════════════════════════════════════════════════════ */
    /*                       CONSTANTS                        */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Total basis points for percentage calculations
    uint128 private constant TOTAL_BIPS = 10000;
    /// @notice Resting fee rate (1%) - always goes to TokenWorks
    uint128 private constant RESTING_FEE = 100;
    /// @notice Starting buy fee rate (99%) - decreases over time
    uint128 private constant STARTING_BUY_FEE = 9900;
    /// @notice Maximum price limit for swaps
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @notice Minimum price limit for swaps
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    /* ═══════════════════════════════════════════════════════ */
    /*                    STATE VARIABLES                      */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Block number when the pool was deployed
    uint256 public deploymentBlock;

    /// @notice The pool ID of the single pool managed by this hook
    PoolId public poolId;

    /// @notice Whether the pool has been initialized
    bool public poolInitialized;

    /// @notice Address to receive the 1% TokenWorks fee
    address public feeAddress;

    /// @notice Address to receive the decaying fee portion (above the 1% resting fee)
    address public buybackAddress;

    /// @notice The CMD token address (currency1 in the pool)
    address public cmdToken;

    /* ═══════════════════════════════════════════════════════ */
    /*                     CUSTOM ERRORS                       */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Pool has already been initialized
    error PoolAlreadyInitialized();
    /// @notice Caller is not the owner
    error NotOwner();
    /// @notice Restrict ExactOutput swaps
    error ExactOutputNotAllowed();

    /* ═══════════════════════════════════════════════════════ */
    /*                     CUSTOM EVENTS                       */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Emitted when fees are collected from a swap
    event HookFee(bytes32 indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
    /// @notice Emitted when a trade occurs in the pool
    event Trade(uint160 sqrtPriceX96, int128 ethAmount, int128 tokenAmount);

    /* ═══════════════════════════════════════════════════════ */
    /*                      CONSTRUCTOR                        */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Initializes the hook with required dependencies
    /// @param _poolManager The Uniswap V4 Pool Manager
    /// @param _owner The owner of this hook
    /// @param _feeAddress Address to receive the 1% TokenWorks fee
    /// @param _buybackAddress Address to receive the decaying fee portion
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _feeAddress,
        address _buybackAddress
    ) BaseHook(_poolManager) {
        _initializeOwner(_owner);
        feeAddress = _feeAddress;
        buybackAddress = _buybackAddress;
    }

    /* ═══════════════════════════════════════════════════════ */
    /*                       FUNCTIONS                         */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Updates the TokenWorks fee address
    /// @param _feeAddress New address to receive the 1% fee
    function updateFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    /// @notice Updates the buyback address for the decaying fee portion
    /// @param _buybackAddress New address to receive buyback fees
    function updateBuybackAddress(address _buybackAddress) external onlyOwner {
        buybackAddress = _buybackAddress;
    }

    /// @notice Withdraws accumulated ETH fees to the fee address
    function withdrawFees() external onlyOwner {
        SafeTransferLib.forceSafeTransferETH(feeAddress, address(this).balance);
    }

    /// @notice Calculates current fee based on blocks since deployment and swap direction
    /// @param isBuying True if buying tokens (ETH -> tokens), false if selling
    /// @return Current fee in basis points
    /// @dev Buy fees decrease from 99% to 1% at 1% per block. Sell fees are constant 1%.
    function calculateFee(bool isBuying) public view returns (uint128) {
        if (!isBuying) return RESTING_FEE;

        uint256 deployedAt = deploymentBlock;
        if (deployedAt == 0) return RESTING_FEE;

        uint256 blocksPassed = block.number - deployedAt;
        uint256 feeReductions = blocksPassed * 100; // 100 bips (1%) per block

        uint256 maxReducible = STARTING_BUY_FEE - RESTING_FEE;
        if (feeReductions >= maxReducible) return RESTING_FEE;

        return uint128(STARTING_BUY_FEE - feeReductions);
    }

    /// @notice Returns the hook's permissions for the Uniswap V4 pool
    /// @return Hooks.Permissions struct indicating which hooks are enabled
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Validates initialization of the pool - only owner, only once
    /// @param key The pool key containing currency pair and hook information
    /// @return Selector indicating successful hook execution
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != owner()) revert NotOwner();
        require(key.currency0.isAddressZero(), "Only ETH/token pools are supported");

        poolInitialized = true;
        poolId = key.toId();
        deploymentBlock = block.number;
        cmdToken = Currency.unwrap(key.currency1);

        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Processes swap events and takes the swap fee
    /// @param sender The address initiating the call (router)
    /// @param key The pool key containing token pair and fee information
    /// @param params Swap parameters including direction and amount
    /// @param delta Balance changes resulting from the swap
    /// @return Hook selector and fee amount taken
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Restrict Exact Out
        if (params.amountSpecified > 0) {
            revert ExactOutputNotAllowed();
        }

        // Calculate fee based on the swap amount
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            (specifiedTokenIs0) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (swapAmount < 0) swapAmount = -swapAmount;

        uint128 currentFee = calculateFee(params.zeroForOne);
        uint256 totalFeeAmount = uint128(swapAmount) * currentFee / TOTAL_BIPS;

        if (totalFeeAmount == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Take the fee from the pool
        poolManager.take(feeCurrency, address(this), totalFeeAmount);

        // Emit the HookFee event
        bool ethFee = Currency.unwrap(feeCurrency) == address(0);
        emit HookFee(
            PoolId.unwrap(key.toId()), sender, ethFee ? uint128(totalFeeAmount) : 0, ethFee ? 0 : uint128(totalFeeAmount)
        );

        // Split: 1% of swap always goes to TokenWorks, anything above 1% goes to buyback
        uint256 twFeeAmount = uint128(swapAmount) * RESTING_FEE / TOTAL_BIPS;
        uint256 buybackFeeAmount = totalFeeAmount - twFeeAmount;

        // Convert to ETH if fee is in tokens, then distribute
        if (!ethFee) {
            uint256 ethReceived = _swapToEth(key, totalFeeAmount);
            uint256 twEth = (ethReceived * twFeeAmount) / totalFeeAmount;
            uint256 buybackEth = ethReceived - twEth;
            SafeTransferLib.forceSafeTransferETH(feeAddress, twEth);
            if (buybackEth > 0) {
                SafeTransferLib.forceSafeTransferETH(buybackAddress, buybackEth);
            }
        } else {
            SafeTransferLib.forceSafeTransferETH(feeAddress, twFeeAmount);
            if (buybackFeeAmount > 0) {
                SafeTransferLib.forceSafeTransferETH(buybackAddress, buybackFeeAmount);
            }
        }

        // Get current price and emit trade event
        emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());

        return (BaseHook.afterSwap.selector, totalFeeAmount.toInt128());
    }

    /// @notice Swaps tokens to ETH for fee collection
    /// @param key The pool key for the swap
    /// @param amount The amount of tokens to swap
    /// @return The amount of ETH received from the swap
    function _swapToEth(PoolKey memory key, uint256 amount) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        // Handle token settlements - always a oneForZero swap
        key.currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
        key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);

        return address(this).balance - ethBefore;
    }

    /// @notice Gets the current price from the pool's slot0
    /// @param key The pool key
    /// @return The current sqrtPriceX96
    function _getCurrentPrice(PoolKey calldata key) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96;
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}