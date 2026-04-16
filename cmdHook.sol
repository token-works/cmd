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

/// @title CMDHook - Uniswap V4 Hook with Decreasing Fee Structure & Adaptive Sell-Pressure Dampener
/// @notice Manages fee collection for a single Uniswap V4 pool with a block-decaying buy fee
///         and a dynamic sell fee that responds to recent sell pressure over a rolling window.
/// @dev Only the owner can initialize the pool. Buy fees decrease from 99% to 1% at 1% per block.
///      Sell fees start at a 1% baseline and increase proportionally when sell volume exceeds a
///      threshold percentage of total supply within a rolling time window, capped at a maximum.
///      Any sell fee above the baseline is routed to the buyback/treasury reserve.
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
    /*            SELL-PRESSURE DAMPENER CONSTANTS             */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Number of buckets in the rolling window
    uint256 private constant NUM_BUCKETS = 12;

    /// @notice Duration of each bucket in seconds (5 minutes each, 12 buckets = 60 minutes)
    uint256 private constant BUCKET_DURATION = 5 minutes;

    /// @notice Sell volume threshold as basis points of total supply (0.5% = 50 bips)
    /// @dev When rolling sell volume exceeds this % of total supply, the sell fee starts increasing
    uint256 private constant SELL_THRESHOLD_BIPS = 50;

    /// @notice Maximum sell fee in basis points (10%)
    uint128 private constant MAX_SELL_FEE = 1000;

    /// @notice Sell fee scaling factor: how aggressively the fee increases above threshold
    /// @dev Fee = RESTING_FEE + (excessRatio * SELL_FEE_SCALE_BIPS), capped at MAX_SELL_FEE
    ///      excessRatio is (excessVolume / thresholdVolume) expressed in bips
    uint256 private constant SELL_FEE_SCALE_BIPS = 900;

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
    /*            SELL-PRESSURE DAMPENER STATE                 */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Rolling window bucket sell volumes (CMD tokens sold into pool)
    uint256[12] public sellBuckets;

    /// @notice Timestamp when each bucket was last written to
    uint256[12] public bucketTimestamps;

    /// @notice The index of the current active bucket
    uint256 public currentBucketIndex;

    /// @notice The timestamp when the current bucket started
    uint256 public currentBucketStart;

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
    /// @notice Emitted when the adaptive sell fee is applied
    event AdaptiveSellFee(uint128 sellFeeBips, uint256 rollingSellVolume, uint256 threshold);

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

    /* ═══════════════════════════════════════════════════════ */
    /*            SELL-PRESSURE DAMPENER LOGIC                 */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Advances the rolling window buckets, clearing stale ones
    function _advanceBuckets() internal {
        if (currentBucketStart == 0) {
            // First call: initialize
            currentBucketStart = block.timestamp;
            currentBucketIndex = 0;
            return;
        }

        uint256 elapsed = block.timestamp - currentBucketStart;
        if (elapsed < BUCKET_DURATION) {
            // Still in the same bucket
            return;
        }

        // How many buckets have passed
        uint256 bucketsPassed = elapsed / BUCKET_DURATION;
        if (bucketsPassed > NUM_BUCKETS) {
            bucketsPassed = NUM_BUCKETS;
        }

        // Clear the buckets that have been passed over
        for (uint256 i = 1; i <= bucketsPassed; i++) {
            uint256 idx = (currentBucketIndex + i) % NUM_BUCKETS;
            sellBuckets[idx] = 0;
            bucketTimestamps[idx] = 0;
        }

        // Move to the new current bucket
        currentBucketIndex = (currentBucketIndex + bucketsPassed) % NUM_BUCKETS;
        currentBucketStart = currentBucketStart + (bucketsPassed * BUCKET_DURATION);
    }

    /// @notice Records a sell volume into the current bucket
    /// @param amount The CMD amount sold
    function _recordSellVolume(uint256 amount) internal {
        _advanceBuckets();
        sellBuckets[currentBucketIndex] += amount;
        bucketTimestamps[currentBucketIndex] = block.timestamp;
    }

    /// @notice Computes the total sell volume across all active (non-stale) buckets
    /// @return total The rolling sell volume
    function getRollingSellVolume() public view returns (uint256 total) {
        if (currentBucketStart == 0) return 0;

        uint256 elapsed = block.timestamp - currentBucketStart;
        uint256 bucketsPassed = elapsed / BUCKET_DURATION;
        if (bucketsPassed > NUM_BUCKETS) {
            // All buckets are stale
            return 0;
        }

        // Sum all buckets, skipping ones that would be cleared by _advanceBuckets
        for (uint256 i = 0; i < NUM_BUCKETS; i++) {
            // Check if this bucket would be cleared
            // Buckets from (currentBucketIndex+1) to (currentBucketIndex+bucketsPassed) would be cleared
            bool wouldBeCleared = false;
            for (uint256 j = 1; j <= bucketsPassed; j++) {
                if (i == (currentBucketIndex + j) % NUM_BUCKETS) {
                    wouldBeCleared = true;
                    break;
                }
            }
            if (!wouldBeCleared) {
                total += sellBuckets[i];
            }
        }
    }

    /// @notice Calculates the adaptive sell fee based on rolling sell pressure
    /// @return The sell fee in basis points
    function calculateSellFee() public view returns (uint128) {
        if (cmdToken == address(0)) return RESTING_FEE;

        uint256 rollingSellVol = getRollingSellVolume();
        uint256 supply = IERC20(cmdToken).totalSupply();
        if (supply == 0) return RESTING_FEE;

        uint256 threshold = (supply * SELL_THRESHOLD_BIPS) / TOTAL_BIPS;
        if (threshold == 0) return RESTING_FEE;

        if (rollingSellVol <= threshold) {
            return RESTING_FEE;
        }

        // Calculate excess ratio in bips: (excess / threshold) * TOTAL_BIPS
        uint256 excess = rollingSellVol - threshold;
        uint256 excessRatioBips = (excess * TOTAL_BIPS) / threshold;

        // Scale the additional fee
        uint256 additionalFee = (excessRatioBips * SELL_FEE_SCALE_BIPS) / TOTAL_BIPS;
        uint256 totalFee = uint256(RESTING_FEE) + additionalFee;

        if (totalFee > MAX_SELL_FEE) {
            totalFee = MAX_SELL_FEE;
        }

        return uint128(totalFee);
    }

    /// @notice Calculates current fee based on blocks since deployment and swap direction
    /// @param isBuying True if buying tokens (ETH -> tokens), false if selling
    /// @return Current fee in basis points
    /// @dev Buy fees decrease from 99% to 1% at 1% per block. Sell fees are adaptive.
    function calculateFee(bool isBuying) public view returns (uint128) {
        if (!isBuying) return calculateSellFee();

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

        // Determine if this is a sell (token -> ETH, i.e. oneForZero where currency1 is CMD)
        // zeroForOne = true means ETH -> CMD (buy)
        // zeroForOne = false means CMD -> ETH (sell)
        bool isSell = !params.zeroForOne;

        // If selling, record the sell volume for the dampener
        if (isSell) {
            // The amount of CMD sold into the pool
            // For a oneForZero swap (sell), delta.amount1() is negative (CMD leaving user)
            // params.amountSpecified is negative (exact input), so the CMD amount is -params.amountSpecified
            int128 cmdDelta = delta.amount1();
            uint256 cmdSold;
            if (cmdDelta < 0) {
                cmdSold = uint256(uint128(-cmdDelta));
            } else {
                cmdSold = uint256(uint128(cmdDelta));
            }
            _recordSellVolume(cmdSold);
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

        // Emit adaptive sell fee info for sells
        if (isSell && currentFee > RESTING_FEE) {
            uint256 supply = IERC20(cmdToken).totalSupply();
            uint256 threshold = (supply * SELL_THRESHOLD_BIPS) / TOTAL_BIPS;
            emit AdaptiveSellFee(currentFee, getRollingSellVolume(), threshold);
        }

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