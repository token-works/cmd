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

/// @title CMDHook - Uniswap V4 Hook with Adaptive Sell-Pressure Dampener
/// @notice Applies a dynamic sell-side fee based on recent sell pressure over a rolling window
/// @dev Buys retain the resting fee. Additional sell fee above baseline is routed to the buyback reserve.
contract CMDHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    /* ═══════════════════════════════════════════════════════ */
    /*                       CONSTANTS                        */
    /* ═══════════════════════════════════════════════════════ */

    uint128 private constant TOTAL_BIPS = 10000;
    uint128 private constant RESTING_FEE = 100;
    uint128 private constant MAX_SELL_FEE = 1000;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint256 public constant WINDOW_DURATION = 60 minutes;
    uint256 public constant EPOCH_DURATION = 5 minutes;
    uint256 public constant WINDOW_EPOCHS = 12;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant SELL_PRESSURE_THRESHOLD_BIPS = 50;

    /* ═══════════════════════════════════════════════════════ */
    /*                    STATE VARIABLES                      */
    /* ═══════════════════════════════════════════════════════ */

    uint256 public deploymentBlock;
    PoolId public poolId;
    bool public poolInitialized;
    address public feeAddress;
    address public buybackAddress;

    uint256[WINDOW_EPOCHS] private sellVolumeBuckets;
    uint256 private bucketCursor;
    uint256 private bucketStartTime;
    uint256 public rollingSellVolume;

    /* ═══════════════════════════════════════════════════════ */
    /*                     CUSTOM ERRORS                       */
    /* ═══════════════════════════════════════════════════════ */

    error PoolAlreadyInitialized();
    error NotOwner();
    error ExactOutputNotAllowed();

    /* ═══════════════════════════════════════════════════════ */
    /*                     CUSTOM EVENTS                       */
    /* ═══════════════════════════════════════════════════════ */

    event HookFee(bytes32 indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
    event Trade(uint160 sqrtPriceX96, int128 ethAmount, int128 tokenAmount);
    event SellPressureUpdated(uint256 rollingSellVolume, uint128 sellFeeBips);

    /* ═══════════════════════════════════════════════════════ */
    /*                      CONSTRUCTOR                        */
    /* ═══════════════════════════════════════════════════════ */

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

    function updateFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    function updateBuybackAddress(address _buybackAddress) external onlyOwner {
        buybackAddress = _buybackAddress;
    }

    function withdrawFees() external onlyOwner {
        SafeTransferLib.forceSafeTransferETH(feeAddress, address(this).balance);
    }

    function calculateFee(bool isBuying) public view returns (uint128) {
        if (isBuying) return RESTING_FEE;
        return _currentSellFee(rollingSellVolume);
    }

    function currentSellFee() external view returns (uint128) {
        return _currentSellFee(_viewRollingSellVolume());
    }

    function currentRollingSellVolume() external view returns (uint256) {
        return _viewRollingSellVolume();
    }

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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != owner()) revert NotOwner();
        require(key.currency0.isAddressZero(), "Only ETH/token pools are supported");

        poolInitialized = true;
        poolId = key.toId();
        deploymentBlock = block.number;
        bucketStartTime = block.timestamp;

        return BaseHook.beforeInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (params.amountSpecified > 0) {
            revert ExactOutputNotAllowed();
        }

        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            (specifiedTokenIs0) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        if (swapAmount < 0) swapAmount = -swapAmount;

        _rollWindow();

        uint128 currentFee;
        uint256 sellAmount;
        if (params.zeroForOne) {
            sellAmount = uint256(uint128(swapAmount));
            _recordSellVolume(sellAmount);
            currentFee = _currentSellFee(rollingSellVolume);
            emit SellPressureUpdated(rollingSellVolume, currentFee);
        } else {
            currentFee = RESTING_FEE;
        }

        uint256 totalFeeAmount = uint128(swapAmount) * currentFee / TOTAL_BIPS;

        if (totalFeeAmount == 0) {
            emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());
            return (BaseHook.afterSwap.selector, 0);
        }

        uint256 baselineFeeAmount = uint128(swapAmount) * RESTING_FEE / TOTAL_BIPS;
        uint256 excessFeeAmount = totalFeeAmount > baselineFeeAmount ? totalFeeAmount - baselineFeeAmount : 0;

        poolManager.take(feeCurrency, address(this), totalFeeAmount);

        bool ethFee = Currency.unwrap(feeCurrency) == address(0);
        emit HookFee(
            PoolId.unwrap(key.toId()), sender, ethFee ? uint128(totalFeeAmount) : 0, ethFee ? 0 : uint128(totalFeeAmount)
        );

        if (!ethFee) {
            uint256 ethReceived = _swapToEth(key, totalFeeAmount);
            uint256 baselineEth = (ethReceived * baselineFeeAmount) / totalFeeAmount;
            uint256 excessEth = ethReceived - baselineEth;
            if (baselineEth > 0) {
                SafeTransferLib.forceSafeTransferETH(feeAddress, baselineEth);
            }
            if (excessEth > 0) {
                SafeTransferLib.forceSafeTransferETH(buybackAddress, excessEth);
            }
        } else {
            if (baselineFeeAmount > 0) {
                SafeTransferLib.forceSafeTransferETH(feeAddress, baselineFeeAmount);
            }
            if (excessFeeAmount > 0) {
                SafeTransferLib.forceSafeTransferETH(buybackAddress, excessFeeAmount);
            }
        }

        emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());

        return (BaseHook.afterSwap.selector, totalFeeAmount.toInt128());
    }

    function _swapToEth(PoolKey memory key, uint256 amount) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        key.currency1.settle(poolManager, address(this), uint256(int256(-delta.amount1())), false);
        key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), false);

        return address(this).balance - ethBefore;
    }

    function _getCurrentPrice(PoolKey calldata key) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96;
    }

    function _rollWindow() internal {
        uint256 start = bucketStartTime;
        if (start == 0) {
            bucketStartTime = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - start;
        if (elapsed < EPOCH_DURATION) return;

        uint256 steps = elapsed / EPOCH_DURATION;
        if (steps >= WINDOW_EPOCHS) {
            for (uint256 i = 0; i < WINDOW_EPOCHS; i++) {
                sellVolumeBuckets[i] = 0;
            }
            rollingSellVolume = 0;
            bucketCursor = 0;
            bucketStartTime = block.timestamp;
            return;
        }

        for (uint256 i = 0; i < steps; i++) {
            bucketCursor = (bucketCursor + 1) % WINDOW_EPOCHS;
            uint256 expired = sellVolumeBuckets[bucketCursor];
            if (expired != 0) {
                rollingSellVolume -= expired;
                sellVolumeBuckets[bucketCursor] = 0;
            }
        }

        bucketStartTime = start + steps * EPOCH_DURATION;
    }

    function _recordSellVolume(uint256 amount) internal {
        sellVolumeBuckets[bucketCursor] += amount;
        rollingSellVolume += amount;
    }

    function _currentSellFee(uint256 sellVolume) internal pure returns (uint128) {
        uint256 thresholdVolume = (INITIAL_SUPPLY * SELL_PRESSURE_THRESHOLD_BIPS) / TOTAL_BIPS;
        if (sellVolume <= thresholdVolume) return RESTING_FEE;

        uint256 excessVolume = sellVolume - thresholdVolume;
        uint256 feeRange = MAX_SELL_FEE - RESTING_FEE;
        uint256 additionalFee = (excessVolume * feeRange) / thresholdVolume;

        if (additionalFee >= feeRange) return MAX_SELL_FEE;
        return uint128(RESTING_FEE + additionalFee);
    }

    function _viewRollingSellVolume() internal view returns (uint256) {
        uint256 start = bucketStartTime;
        if (start == 0) return rollingSellVolume;

        uint256 elapsed = block.timestamp - start;
        if (elapsed < EPOCH_DURATION) return rollingSellVolume;

        uint256 steps = elapsed / EPOCH_DURATION;
        if (steps >= WINDOW_EPOCHS) return 0;

        uint256 simulatedRolling = rollingSellVolume;
        uint256 simulatedCursor = bucketCursor;

        for (uint256 i = 0; i < steps; i++) {
            simulatedCursor = (simulatedCursor + 1) % WINDOW_EPOCHS;
            simulatedRolling -= sellVolumeBuckets[simulatedCursor];
        }

        return simulatedRolling;
    }

    receive() external payable {}
}