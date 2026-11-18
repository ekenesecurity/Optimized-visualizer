// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";

import "../../src/original/UniswapV3Pool.sol";
import "../../src/optimized/OptimizedUniswapV3Pool.sol";
import "../../src/interfaces/IUniswapV3Pool.sol";
import "../../src/interfaces/IUniswapV3PoolDeployer.sol";
import "../../src/interfaces/IERC20Minimal.sol";
import "../../src/interfaces/callback/IUniswapV3MintCallback.sol";
import "../../src/interfaces/callback/IUniswapV3SwapCallback.sol";
import "../../src/interfaces/callback/IUniswapV3FlashCallback.sol";

contract MockERC20 is IERC20Minimal {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "INSUFFICIENT_BALANCE");
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(_balances[sender] >= amount, "INSUFFICIENT_BALANCE");
        require(_allowances[sender][msg.sender] >= amount, "ALLOWANCE");
        _balances[sender] -= amount;
        _allowances[sender][msg.sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }
}

contract PoolDeployer is IUniswapV3PoolDeployer {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    constructor(address _factory, address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    function parameters()
        external
        view
        override
        returns (address _factory, address _token0, address _token1, uint24 _fee, int24 _tickSpacing)
    {
        return (factory, token0, token1, fee, tickSpacing);
    }

    function deployOriginal() external returns (UniswapV3Pool) {
        return new UniswapV3Pool();
    }

    function deployOptimized() external returns (OptimizedUniswapV3Pool) {
        return new OptimizedUniswapV3Pool();
    }
}

contract PoolDifferentialTest is Test, IUniswapV3MintCallback, IUniswapV3SwapCallback, IUniswapV3FlashCallback {
    uint160 internal constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 internal constant INITIAL_BALANCE = uint256(type(uint128).max) * 4;
    uint128 internal constant LIQUIDITY = 100 ether;

    // TickMath bounds for Uniswap V3
    uint160 internal constant MIN_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    int24 internal constant TICK_SPACING = 10;
    int24 internal constant MAX_TICK_MULTIPLE = 88727; // floor(887272 / 10)

    struct SwapFuzzInput {
        int24 rawTickLower;
        int24 rawTickUpper;
        uint128 liquidityAmount;
        bool zeroForOne;
        bool exactInput;
        uint128 rawSwapAmount;
        uint160 rawSqrtPriceLimit;
    }

    struct LifecycleFuzzInput {
        int24 rawTickLower;
        int24 rawTickUpper;
        uint128 mintAmount;
        bool zeroForOne;
        uint128 swapAmount;
        uint128 burnAmount;
        uint32 timeDelta;
    }

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal token0;
    MockERC20 internal token1;

    UniswapV3Pool internal originalPool;
    OptimizedUniswapV3Pool internal optimizedPool;

    function setUp() public {
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        token0.mint(address(this), INITIAL_BALANCE);
        token1.mint(address(this), INITIAL_BALANCE);

        PoolDeployer deployer = new PoolDeployer(address(this), address(token0), address(token1), 500, TICK_SPACING);
        originalPool = deployer.deployOriginal();
        optimizedPool = deployer.deployOptimized();

        originalPool.initialize(SQRT_RATIO_1_1);
        optimizedPool.initialize(SQRT_RATIO_1_1);
    }

    // =========================================================================
    // Helpers & Callbacks
    // =========================================================================

    function _sanitizeTicks(int24 rawLower, int24 rawUpper) internal view returns (int24 tickLower, int24 tickUpper) {
        int256 m1 = bound(int256(rawLower), -int256(MAX_TICK_MULTIPLE), int256(MAX_TICK_MULTIPLE) - 1);
        int256 m2 = bound(int256(rawUpper), m1 + 1, int256(MAX_TICK_MULTIPLE));
        tickLower = int24(m1 * TICK_SPACING);
        tickUpper = int24(m2 * TICK_SPACING);
    }

    function _mintBoth(int24 tickLower, int24 tickUpper, uint128 amount) internal {
        (uint256 a0Orig, uint256 a1Orig) = originalPool.mint(address(this), tickLower, tickUpper, amount, "");
        (uint256 a0Opt, uint256 a1Opt) = optimizedPool.mint(address(this), tickLower, tickUpper, amount, "");
        assertEq(a0Orig, a0Opt, "mint amount0 mismatch");
        assertEq(a1Orig, a1Opt, "mint amount1 mismatch");
    }

    function _swapBoth(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal {
        (int256 a0Orig, int256 a1Orig) = originalPool.swap(
            address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, ""
        );
        (int256 a0Opt, int256 a1Opt) = optimizedPool.swap(
            address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, ""
        );
        assertEq(a0Orig, a0Opt, "swap amount0 mismatch");
        assertEq(a1Orig, a1Opt, "swap amount1 mismatch");
    }

    function _burnBoth(int24 tickLower, int24 tickUpper, uint128 amount) internal {
        (uint256 b0Orig, uint256 b1Orig) = originalPool.burn(tickLower, tickUpper, amount);
        (uint256 b0Opt, uint256 b1Opt) = optimizedPool.burn(tickLower, tickUpper, amount);
        assertEq(b0Orig, b0Opt, "burn amount0 mismatch");
        assertEq(b1Orig, b1Opt, "burn amount1 mismatch");
    }

    function _collectBoth(int24 tickLower, int24 tickUpper, uint128 req0, uint128 req1) internal {
        (uint128 c0Orig, uint128 c1Orig) = originalPool.collect(address(this), tickLower, tickUpper, req0, req1);
        (uint128 c0Opt, uint128 c1Opt) = optimizedPool.collect(address(this), tickLower, tickUpper, req0, req1);
        assertEq(uint256(c0Orig), uint256(c0Opt), "collect amount0 mismatch");
        assertEq(uint256(c1Orig), uint256(c1Opt), "collect amount1 mismatch");
    }

    function assertStorageParity() internal {
        assertEq(vm.load(address(originalPool), bytes32(uint256(0))), vm.load(address(optimizedPool), bytes32(uint256(0))), "slot0 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(1))), vm.load(address(optimizedPool), bytes32(uint256(1))), "feeGrowthGlobal0X128 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(2))), vm.load(address(optimizedPool), bytes32(uint256(2))), "feeGrowthGlobal1X128 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(3))), vm.load(address(optimizedPool), bytes32(uint256(3))), "protocolFees parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(4))), vm.load(address(optimizedPool), bytes32(uint256(4))), "liquidity parity");
        assertEq(token0.balanceOf(address(originalPool)), token0.balanceOf(address(optimizedPool)), "pool token0 balance parity");
        assertEq(token1.balanceOf(address(originalPool)), token1.balanceOf(address(optimizedPool)), "pool token1 balance parity");
    }

    function assertTickParity(int24 tick) internal {
        {
            (uint128 liqGrossOrig, int128 liqNetOrig, uint256 fee0Orig, uint256 fee1Orig, , , , ) = originalPool.ticks(tick);
            (uint128 liqGrossOpt, int128 liqNetOpt, uint256 fee0Opt, uint256 fee1Opt, , , , ) = optimizedPool.ticks(tick);

            assertEq(uint256(liqGrossOrig), uint256(liqGrossOpt), "tick liquidityGross mismatch");
            assertEq(int256(liqNetOrig), int256(liqNetOpt), "tick liquidityNet mismatch");
            assertEq(fee0Orig, fee0Opt, "tick feeGrowthOutside0X128 mismatch");
            assertEq(fee1Orig, fee1Opt, "tick feeGrowthOutside1X128 mismatch");
        }
        {
            (, , , , int56 tickCumOrig, uint160 secPerLiqOrig, uint32 secOutOrig, bool initOrig) = originalPool.ticks(tick);
            (, , , , int56 tickCumOpt, uint160 secPerLiqOpt, uint32 secOutOpt, bool initOpt) = optimizedPool.ticks(tick);

            assertEq(int256(tickCumOrig), int256(tickCumOpt), "tick tickCumulativeOutside mismatch");
            assertEq(uint256(secPerLiqOrig), uint256(secPerLiqOpt), "tick secondsPerLiquidityOutsideX128 mismatch");
            assertEq(uint256(secOutOrig), uint256(secOutOpt), "tick secondsOutside mismatch");
            assertEq(initOrig, initOpt, "tick initialized mismatch");
        }
    }

    function assertPositionParity(address owner, int24 tickLower, int24 tickUpper) internal {
        bytes32 key = keccak256(abi.encodePacked(owner, tickLower, tickUpper));
        {
            (uint128 liqOrig, uint256 fg0Orig, uint256 fg1Orig, , ) = originalPool.positions(key);
            (uint128 liqOpt, uint256 fg0Opt, uint256 fg1Opt, , ) = optimizedPool.positions(key);

            assertEq(uint256(liqOrig), uint256(liqOpt), "position liquidity mismatch");
            assertEq(fg0Orig, fg0Opt, "position feeGrowthInside0LastX128 mismatch");
            assertEq(fg1Orig, fg1Opt, "position feeGrowthInside1LastX128 mismatch");
        }
        {
            (, , , uint128 owed0Orig, uint128 owed1Orig) = originalPool.positions(key);
            (, , , uint128 owed0Opt, uint128 owed1Opt) = optimizedPool.positions(key);

            assertEq(uint256(owed0Orig), uint256(owed0Opt), "position tokensOwed0 mismatch");
            assertEq(uint256(owed1Orig), uint256(owed1Opt), "position tokensOwed1 mismatch");
        }
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata
    ) external override {
        if (amount0Owed > 0) {
            require(token0.transfer(msg.sender, amount0Owed), "mint token0 transfer fail");
        }
        if (amount1Owed > 0) {
            require(token1.transfer(msg.sender, amount1Owed), "mint token1 transfer fail");
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external override {
        if (amount0Delta > 0) {
            require(token0.transfer(msg.sender, uint256(amount0Delta)), "swap token0 transfer fail");
        }
        if (amount1Delta > 0) {
            require(token1.transfer(msg.sender, uint256(amount1Delta)), "swap token1 transfer fail");
        }
    }

    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));

        if (amount0 + fee0 > 0) {
            require(token0.transfer(msg.sender, amount0 + fee0), "flash token0 transfer fail");
        }
        if (amount1 + fee1 > 0) {
            require(token1.transfer(msg.sender, amount1 + fee1), "flash token1 transfer fail");
        }
    }

    function _prepareLiquidityOnBothPools() internal {
        originalPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");
        optimizedPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");
    }

    // =========================================================================
    // Existing Deterministic Tests
    // =========================================================================

    function test_differential_mint() public {
        _mintBoth(-600, 600, uint128(LIQUIDITY));
        assertStorageParity();
    }

    function test_differential_swap() public {
        _prepareLiquidityOnBothPools();
        _swapBoth(true, int256(10 ether), MIN_LIMIT);
        assertStorageParity();
    }

    function test_differential_burnAndCollect() public {
        _prepareLiquidityOnBothPools();
        _burnBoth(-600, 600, uint128(LIQUIDITY / 2));
        _collectBoth(-600, 600, type(uint128).max, type(uint128).max);
        assertStorageParity();
    }

    function test_differential_flash() public {
        _prepareLiquidityOnBothPools();

        bytes memory data = abi.encode(uint256(1 ether), uint256(0));
        originalPool.flash(address(this), 1 ether, 0, data);
        optimizedPool.flash(address(this), 1 ether, 0, data);

        assertStorageParity();
    }

    // =========================================================================
    // Fuzzed Differential Tests
    // =========================================================================

    function testFuzz_differential_initialize(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(uint256(sqrtPriceX96), uint256(MIN_LIMIT), uint256(MAX_LIMIT)));

        PoolDeployer deployer = new PoolDeployer(address(this), address(token0), address(token1), 500, TICK_SPACING);
        UniswapV3Pool freshOrig = deployer.deployOriginal();
        OptimizedUniswapV3Pool freshOpt = deployer.deployOptimized();

        freshOrig.initialize(sqrtPriceX96);
        freshOpt.initialize(sqrtPriceX96);

        assertEq(
            vm.load(address(freshOrig), bytes32(uint256(0))),
            vm.load(address(freshOpt), bytes32(uint256(0))),
            "fuzzed initialize slot0 mismatch"
        );
    }

    function testFuzz_differential_mint(
        int24 rawTickLower,
        int24 rawTickUpper,
        uint128 amount
    ) public {
        (int24 tickLower, int24 tickUpper) = _sanitizeTicks(rawTickLower, rawTickUpper);
        amount = uint128(bound(uint256(amount), 1, uint256(originalPool.maxLiquidityPerTick())));

        _mintBoth(tickLower, tickUpper, amount);

        assertStorageParity();
        assertTickParity(tickLower);
        assertTickParity(tickUpper);
        assertPositionParity(address(this), tickLower, tickUpper);
    }

    function testFuzz_differential_swap(SwapFuzzInput memory input) public {
        (int24 tickLower, int24 tickUpper) = _sanitizeTicks(input.rawTickLower, input.rawTickUpper);

        {
            uint128 maxLiq = originalPool.maxLiquidityPerTick();
            uint128 liq = uint128(bound(uint256(input.liquidityAmount), 1e6, uint256(maxLiq / 2)));

            _mintBoth(tickLower, tickUpper, liq);
            _mintBoth(-6000, 6000, liq);
        }

        {
            uint256 boundedSwap = bound(uint256(input.rawSwapAmount), 1, 1_000_000 ether);
            int256 amountSpecified = input.exactInput ? int256(boundedSwap) : -int256(boundedSwap);

            uint160 sqrtPriceLimitX96 = input.zeroForOne
                ? uint160(bound(uint256(input.rawSqrtPriceLimit), uint256(MIN_LIMIT), uint256(SQRT_RATIO_1_1 - 1)))
                : uint160(bound(uint256(input.rawSqrtPriceLimit), uint256(SQRT_RATIO_1_1 + 1), uint256(MAX_LIMIT)));

            _swapBoth(input.zeroForOne, amountSpecified, sqrtPriceLimitX96);
        }

        assertStorageParity();
        assertTickParity(tickLower);
        assertTickParity(tickUpper);
    }

    function testFuzz_differential_burnAndCollect(
        int24 rawTickLower,
        int24 rawTickUpper,
        uint128 mintAmount,
        uint128 burnAmount,
        uint128 collect0Requested,
        uint128 collect1Requested
    ) public {
        (int24 tickLower, int24 tickUpper) = _sanitizeTicks(rawTickLower, rawTickUpper);

        {
            uint128 boundedMint = uint128(bound(uint256(mintAmount), 1, uint256(originalPool.maxLiquidityPerTick())));
            uint128 boundedBurn = uint128(bound(uint256(burnAmount), 0, uint256(boundedMint)));

            _mintBoth(tickLower, tickUpper, boundedMint);
            _burnBoth(tickLower, tickUpper, boundedBurn);
        }

        assertPositionParity(address(this), tickLower, tickUpper);

        _collectBoth(tickLower, tickUpper, collect0Requested, collect1Requested);

        assertStorageParity();
        assertTickParity(tickLower);
        assertTickParity(tickUpper);
        assertPositionParity(address(this), tickLower, tickUpper);
    }

    function testFuzz_differential_flash(
        uint128 liquidityAmount,
        uint128 rawAmount0,
        uint128 rawAmount1
    ) public {
        liquidityAmount = uint128(bound(uint256(liquidityAmount), 1 ether, uint256(originalPool.maxLiquidityPerTick())));
        _mintBoth(-600, 600, liquidityAmount);

        uint256 amount0 = bound(uint256(rawAmount0), 0, token0.balanceOf(address(originalPool)));
        uint256 amount1 = bound(uint256(rawAmount1), 0, token1.balanceOf(address(originalPool)));
        vm.assume(amount0 > 0 || amount1 > 0);

        bytes memory data = abi.encode(amount0, amount1);
        originalPool.flash(address(this), amount0, amount1, data);
        optimizedPool.flash(address(this), amount0, amount1, data);

        assertStorageParity();
    }

    function testFuzz_differential_fullLifecycle(LifecycleFuzzInput memory input) public {
        int24 tickLower = int24(bound(int256(input.rawTickLower), -6000, -1) * TICK_SPACING);
        int24 tickUpper = int24(bound(int256(input.rawTickUpper), 1, 6000) * TICK_SPACING);

        {
            uint128 mintAmount = uint128(bound(uint256(input.mintAmount), 1e12, 100_000 ether));
            uint128 burnAmount = uint128(bound(uint256(input.burnAmount), 1, uint256(mintAmount)));

            _mintBoth(tickLower, tickUpper, mintAmount);

            vm.warp(block.timestamp + uint32(bound(uint256(input.timeDelta), 1, 7 days)));

            int256 swapAmount = int256(bound(uint256(input.swapAmount), 1000, 10_000 ether));
            uint160 limit = input.zeroForOne ? MIN_LIMIT : MAX_LIMIT;
            _swapBoth(input.zeroForOne, swapAmount, limit);

            _burnBoth(tickLower, tickUpper, burnAmount);
        }

        _collectBoth(tickLower, tickUpper, type(uint128).max, type(uint128).max);

        assertStorageParity();
        assertTickParity(tickLower);
        assertTickParity(tickUpper);
        assertPositionParity(address(this), tickLower, tickUpper);
    }
}
