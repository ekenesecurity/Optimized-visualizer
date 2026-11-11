// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './V3Structs.sol';

import '../interfaces/IUniswapV3Pool.sol';
import '../NoDelegateCall.sol';

import '../libraries/LowGasSafeMath.sol';
import '../libraries/SafeCast.sol';
import '../libraries/Tick.sol';
import '../libraries/TickBitmap.sol';
import '../libraries/Position.sol';
import '../libraries/Oracle.sol';
import '../libraries/FullMath.sol';
import '../libraries/FixedPoint128.sol';
import '../libraries/TransferHelper.sol';
import '../libraries/TickMath.sol';
import '../libraries/LiquidityMath.sol';
import '../libraries/SqrtPriceMath.sol';
import '../libraries/SwapMath.sol';

import '../interfaces/IUniswapV3PoolDeployer.sol';
import '../interfaces/IUniswapV3Factory.sol';
import '../interfaces/IERC20Minimal.sol';
import '../interfaces/callback/IUniswapV3MintCallback.sol';
import '../interfaces/callback/IUniswapV3SwapCallback.sol';
import '../interfaces/callback/IUniswapV3FlashCallback.sol';

contract OptimizedUniswapV3Pool is IUniswapV3Pool, NoDelegateCall,V3Structs {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;
    uint128 public immutable override maxLiquidityPerTick;

    Slot0 public override slot0;
    uint256 public override feeGrowthGlobal0X128;
    uint256 public override feeGrowthGlobal1X128;
    ProtocolFees public override protocolFees;
    uint128 public override liquidity;

    mapping(int24 => Tick.Info) public override ticks;
    mapping(int16 => uint256) public override tickBitmap;
    mapping(bytes32 => Position.Info) public override positions;
    Oracle.Observation[65535] public override observations;

    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    // --- REUSABLE HELPER 1: Unified Token Balance Reader ---
    function _balance(address token) private view returns (uint256) {
        (bool success, bytes memory data) =
                            token.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    // --- REUSABLE HELPER 2: Tick Storage Unpacker ---
    function _getTickOutsideValues(int24 tick)
    private
    view
    returns (int56 tickCumulative, uint160 secondsPerLiquidityX128, uint32 secondsOutside)
    {
        Tick.Info storage info = ticks[tick];
        require(info.initialized);
        return (info.tickCumulativeOutside, info.secondsPerLiquidityOutsideX128, info.secondsOutside);
    }

    // --- REUSABLE HELPER 3: Tick Updater & Bitmap Flipper ---
    function _updateAndFlipTick(
        int24 tickToUpdate,
        int24 currentTick,
        int128 liquidityDelta,
        uint160 secondsPerLiquidity,
        int56 tickCumulative,
        uint32 time,
        bool upper
    ) private returns (bool flipped) {
        flipped = ticks.update(
            tickToUpdate,
            currentTick,
            liquidityDelta,
            feeGrowthGlobal0X128,
            feeGrowthGlobal1X128,
            secondsPerLiquidity,
            tickCumulative,
            time,
            upper,
            maxLiquidityPerTick
        );
        if (flipped) tickBitmap.flipTick(tickToUpdate, tickSpacing);
    }

    // --- REUSABLE HELPER 4: Position Fee Drainer ---
    function _drainTokensOwed(
        address token,
        address recipient,
        uint128 requested,
        uint128 available
    ) private returns (uint128 amount) {
        amount = requested > available ? available : requested;
        if (amount > 0) TransferHelper.safeTransfer(token, recipient, amount);
    }

    // --- REUSABLE HELPER 5: Protocol Fee Drainer (with slot conservation) ---
    function _drainProtocolFee(
        address token,
        address recipient,
        uint128 requested,
        uint128 available
    ) private returns (uint128 amount) {
        amount = requested > available ? available : requested;
        if (amount > 0) {
            if (amount == available) amount--;
            TransferHelper.safeTransfer(token, recipient, amount);
        }
    }

    // --- REUSABLE HELPER 6: Flash Loan Fee Math ---
    function _applyFlashFee(
        uint256 paid,
        uint8 feeProtocol,
        uint128 _liquidity
    ) private pure returns (uint128 pFee, uint256 feeGrowthDelta) {
        if (paid > 0) {
            uint256 fees = feeProtocol == 0 ? 0 : paid / feeProtocol;
            pFee = uint128(fees);
            feeGrowthDelta = FullMath.mulDiv(paid - fees, FixedPoint128.Q128, _liquidity);
        }
    }

    function _settleFlashFees(uint256 paid0, uint256 paid1, uint128 poolLiquidity, uint8 feeProtocol) private {
        if (paid0 > 0) {
            (uint128 pFee0, uint256 delta0) = _applyFlashFee(paid0, feeProtocol % 16, poolLiquidity);
            if (pFee0 > 0) protocolFees.token0 += pFee0;
            if (delta0 > 0) feeGrowthGlobal0X128 += delta0;
        }
        if (paid1 > 0) {
            (uint128 pFee1, uint256 delta1) = _applyFlashFee(paid1, feeProtocol >> 4, poolLiquidity);
            if (pFee1 > 0) protocolFees.token1 += pFee1;
            if (delta1 > 0) feeGrowthGlobal1X128 += delta1;
        }
    }

    // --- REUSABLE HELPER 7: Mint Callback Balance Check ---
    function _verifyBalanceDelta(
        address token,
        uint256 balanceBefore,
        uint256 amountExpected,
        string memory err
    ) private view {
        if (amountExpected > 0) require(balanceBefore.add(amountExpected) <= _balance(token), err);
    }

    // --- REUSABLE HELPER 8: Fee Protocol Validator ---
    function _validateFeeProtocol(uint8 feeProtocol) private pure {
        require(feeProtocol == 0 || (feeProtocol >= 4 && feeProtocol <= 10));
    }

    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
    external
    view
    override
    noDelegateCall
    returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
    {
        checkTicks(tickLower, tickUpper);

        (int56 lowerTick, uint160 lowerSecLiq, uint32 lowerSec) = _getTickOutsideValues(tickLower);
        (int56 upperTick, uint160 upperSecLiq, uint32 upperSec) = _getTickOutsideValues(tickUpper);

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (lowerTick - upperTick, lowerSecLiq - upperSecLiq, lowerSec - upperSec);
        }
        if (_slot0.tick >= tickUpper) {
            return (upperTick - lowerTick, upperSecLiq - lowerSecLiq, upperSec - lowerSec);
        }

        uint32 time = _blockTimestamp();
        (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
            time, 0, _slot0.tick, _slot0.observationIndex, liquidity, _slot0.observationCardinality
        );
        return (
            tickCumulative - lowerTick - upperTick,
            secondsPerLiquidityCumulativeX128 - lowerSecLiq - upperSecLiq,
            time - lowerSec - upperSec
        );
    }

    function observe(uint32[] calldata secondsAgos)
    external
    view
    override
    noDelegateCall
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return observations.observe(
            _blockTimestamp(), secondsAgos, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
        );
    }

    function increaseObservationCardinalityNext(uint16 next) external override lock noDelegateCall {
        uint16 current = slot0.observationCardinalityNext;
        uint16 updated = observations.grow(current, next);
        slot0.observationCardinalityNext = updated;
        if (current != updated) emit IncreaseObservationCardinalityNext(current, updated);
    }

    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    function _modifyPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) private noDelegateCall returns (Position.Info storage position, uint256 amount0, uint256 amount1) {
        checkTicks(tickLower, tickUpper);
        Slot0 memory _slot0 = slot0;

        position = _updatePosition(owner, tickLower, tickUpper, liquidityDelta, _slot0.tick);

        if (liquidityDelta != 0) {
            int256 a0;
            int256 a1;

            if (_slot0.tick < tickLower) {
                a0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidityDelta
                );
            } else if (_slot0.tick < tickUpper) {
                uint128 liquidityBefore = liquidity;
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );
                a0 = SqrtPriceMath.getAmount0Delta(_slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickUpper), liquidityDelta);
                a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(tickLower), _slot0.sqrtPriceX96, liquidityDelta);
                liquidity = LiquidityMath.addDelta(liquidityBefore, liquidityDelta);
            } else {
                a1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidityDelta
                );
            }

            if (liquidityDelta < 0) {
                (amount0, amount1) = (uint256(-a0), uint256(-a1));
            } else {
                (amount0, amount1) = (uint256(a0), uint256(a1));
            }
        }
    }

    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper);

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time, 0, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
            );

            flippedLower = _updateAndFlipTick(
                tickLower, tick, liquidityDelta, secondsPerLiquidityCumulativeX128, tickCumulative, time, false
            );
            flippedUpper = _updateAndFlipTick(
                tickUpper, tick, liquidityDelta, secondsPerLiquidityCumulativeX128, tickCumulative, time, true
            );
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            tickLower, tickUpper, tick, feeGrowthGlobal0X128, feeGrowthGlobal1X128
        );

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        if (liquidityDelta < 0) {
            if (flippedLower) ticks.clear(tickLower);
            if (flippedUpper) ticks.clear(tickUpper);
        }
    }

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        (, amount0, amount1) = _modifyPosition(recipient, tickLower, tickUpper, int256(amount).toInt128());

        uint256 balance0Before = amount0 > 0 ? _balance(token0) : 0;
        uint256 balance1Before = amount1 > 0 ? _balance(token1) : 0;

        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        _verifyBalanceDelta(token0, balance0Before, amount0, 'M0');
        _verifyBalanceDelta(token1, balance1Before, amount1, 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = _drainTokensOwed(token0, recipient, amount0Requested, position.tokensOwed0);
        position.tokensOwed0 -= amount0;

        amount1 = _drainTokensOwed(token1, recipient, amount1Requested, position.tokensOwed1);
        position.tokensOwed1 -= amount1;

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        Position.Info storage position;
        (position, amount0, amount1) = _modifyPosition(msg.sender, tickLower, tickUpper, -int256(amount).toInt128());

        if (amount0 > 0 || amount1 > 0) {
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');

        Slot0 memory slot0Start = slot0;
        require(slot0Start.unlocked, 'LOK');
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false;

        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick, tickSpacing, zeroForOne
            );

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp, 0, slot0Start.tick, slot0Start.observationIndex, cache.liquidityStart, slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0Start.observationIndex, cache.blockTimestamp, slot0Start.tick, cache.liquidityStart,
                slot0Start.observationCardinality, slot0Start.observationCardinalityNext
            );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96, state.tick, observationIndex, observationCardinality
            );
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        address tokenIn = zeroForOne ? token0 : token1;
        int256 amountOut = zeroForOne ? amount1 : amount0;
        if (amountOut < 0) TransferHelper.safeTransfer(zeroForOne ? token1 : token0, recipient, uint256(-amountOut));

        uint256 balanceBefore = _balance(tokenIn);
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(balanceBefore.add(uint256(zeroForOne ? amount0 : amount1)) <= _balance(tokenIn), 'IIA');

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = _balance(token0);
        uint256 balance1Before = _balance(token1);

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 paid0 = _balance(token0) - balance0Before;
        uint256 paid1 = _balance(token1) - balance1Before;

        require(paid0 >= fee0, 'F0');
        require(paid1 >= fee1, 'F1');

        _settleFlashFees(paid0, paid1, _liquidity, slot0.feeProtocol);

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        _validateFeeProtocol(feeProtocol0);
        _validateFeeProtocol(feeProtocol1);

        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = _drainProtocolFee(token0, recipient, amount0Requested, protocolFees.token0);
        protocolFees.token0 -= amount0;

        amount1 = _drainProtocolFee(token1, recipient, amount1Requested, protocolFees.token1);
        protocolFees.token1 -= amount1;

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}