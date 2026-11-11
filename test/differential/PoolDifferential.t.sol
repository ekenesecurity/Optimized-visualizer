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
    uint256 internal constant INITIAL_BALANCE = 1_000_000 ether;
    uint128 internal constant LIQUIDITY = 100 ether;
    uint160 internal constant MIN_LIMIT = 4295128739 + 1;

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

        PoolDeployer deployer = new PoolDeployer(address(this), address(token0), address(token1), 500, 10);
        originalPool = deployer.deployOriginal();
        optimizedPool = deployer.deployOptimized();

        originalPool.initialize(SQRT_RATIO_1_1);
        optimizedPool.initialize(SQRT_RATIO_1_1);
    }

    function _mintLiquidity(address pool, int24 tickLower, int24 tickUpper, uint128 amount) internal {
        IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, amount, "");
    }

    function assertStorageParity() internal {
        assertEq(vm.load(address(originalPool), bytes32(uint256(0))), vm.load(address(optimizedPool), bytes32(uint256(0))), "slot0 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(1))), vm.load(address(optimizedPool), bytes32(uint256(1))), "feeGrowthGlobal0X128 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(2))), vm.load(address(optimizedPool), bytes32(uint256(2))), "feeGrowthGlobal1X128 parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(3))), vm.load(address(optimizedPool), bytes32(uint256(3))), "protocolFees parity");
        assertEq(vm.load(address(originalPool), bytes32(uint256(4))), vm.load(address(optimizedPool), bytes32(uint256(4))), "liquidity parity");
    }

    function _fundPoolForMint(address pool, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            require(token0.transfer(pool, amount0), "fund pool token0");
        }
        if (amount1 > 0) {
            require(token1.transfer(pool, amount1), "fund pool token1");
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

        if (amount0 > 0) {
            require(token0.transfer(msg.sender, amount0 + fee0), "flash token0 transfer fail");
        }
        if (amount1 > 0) {
            require(token1.transfer(msg.sender, amount1 + fee1), "flash token1 transfer fail");
        }
    }

    function _prepareLiquidityOnBothPools() internal {
        originalPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");
        optimizedPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");
    }

    function test_differential_mint() public {
        (uint256 amount0Orig, uint256 amount1Orig) = originalPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");
        (uint256 amount0Opt, uint256 amount1Opt) = optimizedPool.mint(address(this), -600, 600, uint128(LIQUIDITY), "");

        assertEq(amount0Orig, amount0Opt, "mint amount0 mismatch");
        assertEq(amount1Orig, amount1Opt, "mint amount1 mismatch");
        assertStorageParity();
    }

    function test_differential_swap() public {
        _prepareLiquidityOnBothPools();

        (int256 amount0Orig, int256 amount1Orig) = originalPool.swap(
            address(this), true, int256(10 ether), MIN_LIMIT, ""
        );
        (int256 amount0Opt, int256 amount1Opt) = optimizedPool.swap(
            address(this), true, int256(10 ether), MIN_LIMIT, ""
        );

        assertEq(amount0Orig, amount0Opt, "swap amount0 mismatch");
        assertEq(amount1Orig, amount1Opt, "swap amount1 mismatch");
        assertStorageParity();
    }

    function test_differential_burnAndCollect() public {
        _prepareLiquidityOnBothPools();

        (uint256 burn0Orig, uint256 burn1Orig) = originalPool.burn(-600, 600, uint128(LIQUIDITY / 2));
        (uint256 burn0Opt, uint256 burn1Opt) = optimizedPool.burn(-600, 600, uint128(LIQUIDITY / 2));

        assertEq(burn0Orig, burn0Opt, "burn amount0 mismatch");
        assertEq(burn1Orig, burn1Opt, "burn amount1 mismatch");

        (uint128 collect0Orig, uint128 collect1Orig) = originalPool.collect(
            address(this), -600, 600, type(uint128).max, type(uint128).max
        );
        (uint128 collect0Opt, uint128 collect1Opt) = optimizedPool.collect(
            address(this), -600, 600, type(uint128).max, type(uint128).max
        );

        assertEq(uint256(collect0Orig), uint256(collect0Opt), "collect amount0 mismatch");
        assertEq(uint256(collect1Orig), uint256(collect1Opt), "collect amount1 mismatch");
        assertStorageParity();
    }

    function test_differential_flash() public {
        _prepareLiquidityOnBothPools();

        bytes memory data = abi.encode(uint256(1 ether), uint256(0));
        originalPool.flash(address(this), 1 ether, 0, data);
        optimizedPool.flash(address(this), 1 ether, 0, data);

        assertStorageParity();
    }
}
