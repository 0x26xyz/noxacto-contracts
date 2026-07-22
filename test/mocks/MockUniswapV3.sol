// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {TickMath, LiquidityAmounts} from "./UniswapV3Math.sol";

/// @dev TEST-ONLY mock of the slice of Uniswap V3 the launchpad touches:
/// Factory (create/get pool), Pool (initialize/slot0), and the
/// NonfungiblePositionManager (mint/collect/positions + ERC-721 custody).
///
/// The position manager reproduces the REAL single-sided amount computation via
/// the vendored V3 math, so the amounts pulled on mint — and therefore the L3
/// "zero WETH consumed" assertion in LaunchpadFactory — are faithful, not stubs.

/// @notice Minimal Uniswap V3 pool: stores the sorted token pair + current price.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint160 public sqrtPriceX96;
    bool public initialized;

    error AlreadyInitialized();

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function initialize(uint160 sqrtPriceX96_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    /// @dev tick is not derived (unused by the launchpad); returned as 0.
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96_, int24 tick, uint16, uint16, uint16, uint8, bool unlocked)
    {
        return (sqrtPriceX96, int24(0), uint16(0), uint16(0), uint16(0), uint8(0), initialized);
    }
}

/// @notice Minimal Uniswap V3 factory: deploys + indexes pools per (pair, fee).
contract MockUniswapV3Factory {
    int24 public constant TICK_SPACING_1PCT = 200;

    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, address pool);

    error PoolExists();
    error IdenticalTokens();
    error ZeroToken();

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroToken();
        if (getPool[token0][token1][fee] != address(0)) revert PoolExists();

        pool = address(new MockUniswapV3Pool(token0, token1, fee, TICK_SPACING_1PCT));
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, pool);
    }
}

/// @notice Minimal Uniswap V3 NonfungiblePositionManager: ERC-721 positions with
/// faithful single-sided mint amounts, fee collection, and a test-only fee
/// accrual hook. Matches the selectors the launchpad calls; not a full ERC-721.
contract MockNonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    MockUniswapV3Factory public immutable factory;

    uint256 public nextId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => Position) internal _positions;

    error PoolNotFound();
    error PriceSlippage();
    error NotOwner();
    error NotAuthorized();
    error NonexistentToken();
    error UnsafeRecipient();
    error Expired();

    constructor(address factory_) {
        factory = MockUniswapV3Factory(factory_);
    }

    function mint(MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > p.deadline) revert Expired();
        address pool = factory.getPool(p.token0, p.token1, p.fee);
        if (pool == address(0)) revert PoolNotFound();

        (uint160 sqrtP,,,,,,) = MockUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(p.tickUpper);

        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, p.amount0Desired, p.amount1Desired);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);

        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert PriceSlippage();

        // Pull the owed amounts from the minter (the launch factory). The mock
        // holds the deposited tokens itself, standing in for the pool reserves.
        if (amount0 > 0) IERC20(p.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(p.token1).transferFrom(msg.sender, address(this), amount1);

        tokenId = nextId++;
        _positions[tokenId] = Position({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: liquidity,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
        ownerOf[tokenId] = p.recipient;
    }

    function collect(CollectParams calldata p) external payable returns (uint256 amount0, uint256 amount1) {
        Position storage pos = _positions[p.tokenId];
        if (ownerOf[p.tokenId] == address(0)) revert NonexistentToken();

        uint128 owed0 = pos.tokensOwed0;
        uint128 owed1 = pos.tokensOwed1;
        amount0 = p.amount0Max < owed0 ? p.amount0Max : owed0;
        amount1 = p.amount1Max < owed1 ? p.amount1Max : owed1;

        pos.tokensOwed0 = owed0 - uint128(amount0);
        pos.tokensOwed1 = owed1 - uint128(amount1);

        if (amount0 > 0) IERC20(pos.token0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(pos.token1).transfer(p.recipient, amount1);
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        if (ownerOf[tokenId] == address(0)) revert NonexistentToken();
        Position memory pos = _positions[tokenId];
        return (0, address(0), pos.token0, pos.token1, pos.fee, pos.tickLower, pos.tickUpper, pos.liquidity, 0, 0, pos.tokensOwed0, pos.tokensOwed1);
    }

    /// @dev Plain (non-safe) transfer: moves ownership WITHOUT the onERC721Received
    /// callback — the footgun `NoxaLpLock.lockDirectTransfer` recovers from.
    function transferFrom(address from, address to, uint256 tokenId) external {
        address owner = ownerOf[tokenId];
        if (owner != from) revert NotOwner();
        if (msg.sender != owner) revert NotAuthorized();
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        address owner = ownerOf[tokenId];
        if (owner != from) revert NotOwner();
        // Real Uniswap PM requires msg.sender to be owner/approved. The locker
        // never approves anyone, so once it owns the NFT nobody can move it —
        // that is the on-chain teeth behind invariant L1.
        if (msg.sender != owner) revert NotAuthorized();
        ownerOf[tokenId] = to;
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
            if (ret != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        }
    }

    // --- test-only helpers ---

    /// @dev Simulate accrued V3 trading fees on a position. Caller must have
    /// pre-funded this contract with the corresponding token balances.
    function simulateFees(uint256 tokenId, uint128 add0, uint128 add1) external {
        Position storage pos = _positions[tokenId];
        require(ownerOf[tokenId] != address(0), "no position");
        pos.tokensOwed0 += add0;
        pos.tokensOwed1 += add1;
    }
}
