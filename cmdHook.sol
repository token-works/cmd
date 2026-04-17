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

interface ICommandToken {
    function balanceOf(address account) external view returns (uint256);
    function burnFromHook(address from, uint256 amount) external;
}

/// @title CMDHook - Uniswap V4 Hook with sell-pressure rewards, buybacks, and public guessing events
contract CMDHook is BaseHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    uint128 private constant TOTAL_BIPS = 10000;
    uint128 private constant RESTING_FEE = 100;
    uint128 private constant MAX_SELL_FEE = 1000;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 public constant WINDOW_DURATION = 60 minutes;
    uint256 public constant EPOCH_DURATION = 5 minutes;
    uint256 public constant WINDOW_EPOCHS = 12;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant SELL_PRESSURE_THRESHOLD_BIPS = 50;

    uint256 public constant CHALLENGE_DURATION = 30 minutes;
    uint256 public constant MIN_ANSWER = 1;
    uint256 public constant MAX_ANSWER = 1000;

    uint256 public constant BASELINE_FEE_TO_PROTOCOL_BIPS = 2000;
    uint256 public constant BASELINE_FEE_TO_REWARD_POOL_BIPS = 3000;
    uint256 public constant BASELINE_FEE_TO_BUYBACK_BIPS = 3000;
    uint256 public constant BASELINE_FEE_TO_BURN_BIPS = 2000;

    uint256 public constant EXCESS_FEE_TO_REWARD_POOL_BIPS = 7000;
    uint256 public constant EXCESS_FEE_TO_BUYBACK_BIPS = 2000;
    uint256 public constant EXCESS_FEE_TO_BURN_BIPS = 1000;

    uint256 public constant BUY_BOOST_TO_POOL_BIPS = 5000;
    uint256 public constant BUY_BOOST_TO_BUYBACK_BIPS = 3000;
    uint256 public constant BUY_BOOST_TO_BURN_BIPS = 2000;

    uint256 public constant SELL_DIRECT_BURN_BIPS = 2000;
    uint256 public constant EVENT_WINNER_BIPS = 5000;
    uint256 public constant EVENT_BUYBACK_BIPS = 3000;
    uint256 public constant EVENT_BURN_BIPS = 2000;

    uint256 public constant FAIL_BURN_BIPS = 7000;
    uint256 public constant FAIL_ROLLOVER_BIPS = 3000;

    uint256 public challengeThreshold = 5 ether;
    uint256 public buyBoostAmount = 0.01 ether;

    uint256 public deploymentBlock;
    PoolId public poolId;
    bool public poolInitialized;
    address public feeAddress;
    address public buybackAddress;

    uint256[WINDOW_EPOCHS] private sellVolumeBuckets;
    uint256 private bucketCursor;
    uint256 private bucketStartTime;
    uint256 public rollingSellVolume;

    PoolKey public activePoolKey;
    bool public activePoolKeySet;
    address public cmdToken;
    bool public cmdIsCurrency0;

    uint256 public rewardPool;

    struct ChallengeEvent {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 poolAmount;
        uint256 seed;
        uint256 winningAnswer;
        address winner;
        bool settled;
        bool success;
    }

    uint256 public nextEventId;
    uint256 public activeEventId;
    mapping(uint256 => ChallengeEvent) public challengeEvents;
    mapping(uint256 => mapping(address => uint8)) public guessesUsed;

    error PoolAlreadyInitialized();
    error NotOwner();
    error ExactOutputNotAllowed();
    error InvalidCommandToken();
    error NoActiveChallenge();
    error ChallengeInactive();
    error ChallengeExpired();
    error GuessOutOfRange();
    error GuessLimitReached();
    error ChallengeAlreadySettled();
    error ActiveChallengeExists();
    error NothingToSettle();
    error InvalidBoostValue();

    event HookFee(bytes32 indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);
    event Trade(uint160 sqrtPriceX96, int128 ethAmount, int128 tokenAmount);
    event SellPressureUpdated(uint256 rollingSellVolume, uint128 sellFeeBips);

    event RewardPoolFunded(uint256 amount, uint256 newRewardPool, bool fromSell);
    event BuybackFunded(uint256 amount);
    event SellBurn(uint256 amount);
    event BuyBoost(address indexed user, uint256 amount, uint256 poolAdded, uint256 buybackAdded, uint256 burnValue);
    event ChallengeStarted(uint256 indexed eventId, uint256 startTime, uint256 endTime, uint256 poolAmount);
    event GuessSubmitted(uint256 indexed eventId, address indexed user, uint256 answer, uint8 guessNumber);
    event ChallengeWon(uint256 indexed eventId, address indexed winner, uint256 winnerReward, uint256 buybackAmount, uint256 burnAmount);
    event ChallengeFailed(uint256 indexed eventId, uint256 burnedAmount, uint256 rolloverAmount);

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

    function updateFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    function updateBuybackAddress(address _buybackAddress) external onlyOwner {
        buybackAddress = _buybackAddress;
    }

    function updateChallengeThreshold(uint256 newThreshold) external onlyOwner {
        challengeThreshold = newThreshold;
    }

    function updateBuyBoostAmount(uint256 newAmount) external onlyOwner {
        buyBoostAmount = newAmount;
    }

    function withdrawFees() external onlyOwner {
        uint256 available = address(this).balance;
        if (available > rewardPool) {
            SafeTransferLib.forceSafeTransferETH(feeAddress, available - rewardPool);
        }
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

    function currentSecretHint(uint256 eventId) external view returns (uint256) {
        ChallengeEvent storage e = challengeEvents[eventId];
        if (e.startTime == 0) return 0;
        return (e.seed % 97) + 1;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwap: false,
            afterSwap: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function boostChallenge() external payable nonReentrant {
        if (msg.value != buyBoostAmount) revert InvalidBoostValue();

        uint256 toPool = (msg.value * BUY_BOOST_TO_POOL_BIPS) / TOTAL_BIPS;
        uint256 toBuyback = (msg.value * BUY_BOOST_TO_BUYBACK_BIPS) / TOTAL_BIPS;
        uint256 toBurn = msg.value - toPool - toBuyback;

        if (toPool > 0) {
            rewardPool += toPool;
            emit RewardPoolFunded(toPool, rewardPool, false);
        }
        if (toBuyback > 0) {
            SafeTransferLib.forceSafeTransferETH(buybackAddress, toBuyback);
            emit BuybackFunded(toBuyback);
        }
        emit BuyBoost(msg.sender, msg.value, toPool, toBuyback, toBurn);

        _maybeStartChallenge();
    }

    function guess(uint256 eventId, uint256 answer) external nonReentrant {
        if (answer < MIN_ANSWER || answer > MAX_ANSWER) revert GuessOutOfRange();
        if (eventId != activeEventId || eventId == 0) revert NoActiveChallenge();

        ChallengeEvent storage e = challengeEvents[eventId];
        if (e.settled) revert ChallengeAlreadySettled();
        if (block.timestamp >= e.endTime) revert ChallengeExpired();

        uint8 used = guessesUsed[eventId][msg.sender];
        if (used >= 3) revert GuessLimitReached();

        guessesUsed[eventId][msg.sender] = used + 1;
        emit GuessSubmitted(eventId, msg.sender, answer, used + 1);

        if (answer == e.winningAnswer) {
            e.winner = msg.sender;
            e.success = true;
            _settleSuccessfulChallenge(e);
        }
    }

    function settleExpiredChallenge(uint256 eventId) external nonReentrant {
        if (eventId != activeEventId || eventId == 0) revert NoActiveChallenge();

        ChallengeEvent storage e = challengeEvents[eventId];
        if (e.settled) revert ChallengeAlreadySettled();
        if (block.timestamp < e.endTime) revert ChallengeInactive();

        _settleFailedChallenge(e);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (sender != owner()) revert NotOwner();
        require(key.currency0.isAddressZero(), "Only ETH/token pools are supported");

        poolInitialized = true;
        poolId = key.toId();
        deploymentBlock = block.number;
        bucketStartTime = block.timestamp;
        activePoolKey = key;
        activePoolKeySet = true;

        address tokenAddress = Currency.unwrap(key.currency1);
        if (tokenAddress == address(0)) revert InvalidCommandToken();
        cmdToken = tokenAddress;
        cmdIsCurrency0 = false;

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

        uint256 feeValueEth;
        if (!ethFee) {
            feeValueEth = _swapToEth(key, totalFeeAmount);
        } else {
            feeValueEth = totalFeeAmount;
        }

        _distributeFeeValue(params.zeroForOne, feeValueEth, baselineFeeAmount, excessFeeAmount);

        emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());
        return (BaseHook.afterSwap.selector, totalFeeAmount.toInt128());
    }

    function _distributeFeeValue(
        bool isSell,
        uint256 ethValue,
        uint256 baselineFeeAmount,
        uint256 excessFeeAmount
    ) internal {
        uint256 totalFeeAmount = baselineFeeAmount + excessFeeAmount;
        if (ethValue == 0 || totalFeeAmount == 0) return;

        uint256 baselineEth = (ethValue * baselineFeeAmount) / totalFeeAmount;
        uint256 excessEth = ethValue - baselineEth;

        uint256 toProtocol = (baselineEth * BASELINE_FEE_TO_PROTOCOL_BIPS) / TOTAL_BIPS;
        uint256 toPool = (baselineEth * BASELINE_FEE_TO_REWARD_POOL_BIPS) / TOTAL_BIPS;
        uint256 toBuyback = (baselineEth * BASELINE_FEE_TO_BUYBACK_BIPS) / TOTAL_BIPS;
        uint256 toBurn = baselineEth - toProtocol - toPool - toBuyback;

        if (excessEth > 0) {
            toPool += (excessEth * EXCESS_FEE_TO_REWARD_POOL_BIPS) / TOTAL_BIPS;
            toBuyback += (excessEth * EXCESS_FEE_TO_BUYBACK_BIPS) / TOTAL_BIPS;
            toBurn += excessEth - ((excessEth * EXCESS_FEE_TO_REWARD_POOL_BIPS) / TOTAL_BIPS) - ((excessEth * EXCESS_FEE_TO_BUYBACK_BIPS) / TOTAL_BIPS);
        }

        if (isSell && toBurn > 0) {
            emit SellBurn(toBurn);
        }

        if (toProtocol > 0) {
            SafeTransferLib.forceSafeTransferETH(feeAddress, toProtocol);
        }
        if (toBuyback > 0) {
            SafeTransferLib.forceSafeTransferETH(buybackAddress, toBuyback);
            emit BuybackFunded(toBuyback);
        }
        if (toPool > 0) {
            rewardPool += toPool;
            emit RewardPoolFunded(toPool, rewardPool, isSell);
            _maybeStartChallenge();
        }
    }

    function _maybeStartChallenge() internal {
        if (activeEventId != 0) {
            ChallengeEvent storage active = challengeEvents[activeEventId];
            if (!active.settled && block.timestamp < active.endTime) {
                return;
            }
        }

        if (rewardPool < challengeThreshold) return;

        uint256 eventId = ++nextEventId;
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.timestamp,
                    rewardPool,
                    rollingSellVolume,
                    eventId,
                    address(this)
                )
            )
        );
        uint256 winningAnswer = (seed % MAX_ANSWER) + MIN_ANSWER;

        challengeEvents[eventId] = ChallengeEvent({
            id: eventId,
            startTime: block.timestamp,
            endTime: block.timestamp + CHALLENGE_DURATION,
            poolAmount: rewardPool,
            seed: seed,
            winningAnswer: winningAnswer,
            winner: address(0),
            settled: false,
            success: false
        });

        activeEventId = eventId;
        emit ChallengeStarted(eventId, block.timestamp, block.timestamp + CHALLENGE_DURATION, rewardPool);
    }

    function _settleSuccessfulChallenge(ChallengeEvent storage e) internal {
        uint256 poolAmount = e.poolAmount;
        if (poolAmount == 0 || rewardPool < poolAmount) revert NothingToSettle();

        rewardPool -= poolAmount;
        e.settled = true;

        uint256 winnerReward = (poolAmount * EVENT_WINNER_BIPS) / TOTAL_BIPS;
        uint256 buybackAmount = (poolAmount * EVENT_BUYBACK_BIPS) / TOTAL_BIPS;
        uint256 burnAmount = poolAmount - winnerReward - buybackAmount;

        if (winnerReward > 0) {
            SafeTransferLib.forceSafeTransferETH(e.winner, winnerReward);
        }
        if (buybackAmount > 0) {
            SafeTransferLib.forceSafeTransferETH(buybackAddress, buybackAmount);
            emit BuybackFunded(buybackAmount);
        }

        activeEventId = 0;
        emit ChallengeWon(e.id, e.winner, winnerReward, buybackAmount, burnAmount);

        _maybeStartChallenge();
    }

    function _settleFailedChallenge(ChallengeEvent storage e) internal {
        uint256 poolAmount = e.poolAmount;
        if (poolAmount == 0 || rewardPool < poolAmount) revert NothingToSettle();

        rewardPool -= poolAmount;
        e.settled = true;
        e.success = false;

        uint256 rolloverAmount = (poolAmount * FAIL_ROLLOVER_BIPS) / TOTAL_BIPS;
        uint256 burnedAmount = poolAmount - rolloverAmount;

        if (rolloverAmount > 0) {
            rewardPool += rolloverAmount;
        }

        activeEventId = 0;
        emit ChallengeFailed(e.id, burnedAmount, rolloverAmount);

        _maybeStartChallenge();
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