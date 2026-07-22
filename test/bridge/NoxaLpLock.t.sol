// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {NoxaLpLock} from "../../src/bridge/NoxaLpLock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool, MockNonfungiblePositionManager} from "../mocks/MockUniswapV3.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";

/// @dev Exercises the permanent locker: it takes exactly one position from the
/// PM, forwards fees to `feeRecipient`, and never lets the NFT out.
contract NoxaLpLockTest is Test {
    MockUniswapV3Factory internal v3Factory;
    MockNonfungiblePositionManager internal pm;
    MockERC20 internal wnoxa;
    MockERC20 internal weth;
    NoxaLpLock internal lock;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seeder = makeAddr("seeder");

    // 1:1 price, sqrt(1) << 96
    uint160 internal constant SQRT_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;

    function setUp() public {
        v3Factory = new MockUniswapV3Factory();
        pm = new MockNonfungiblePositionManager(address(v3Factory));
        wnoxa = new MockERC20("Wrapped NOXA", "wNOXA", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        lock = new NoxaLpLock(address(pm), feeRecipient, seeder, address(wnoxa), address(weth), FEE);
    }

    function _seedPosition(uint256 amount) internal returns (uint256 tokenId) {
        (address t0, address t1) =
            address(wnoxa) < address(weth) ? (address(wnoxa), address(weth)) : (address(weth), address(wnoxa));
        address pool = v3Factory.createPool(t0, t1, FEE);
        MockUniswapV3Pool(pool).initialize(SQRT_1);

        wnoxa.mint(seeder, amount);
        vm.startPrank(seeder);
        wnoxa.approve(address(pm), amount);
        bool tokenIsToken0 = address(wnoxa) < address(weth);
        (uint256 a0, uint256 a1) = tokenIsToken0 ? (amount, uint256(0)) : (uint256(0), amount);
        // Range fully on the token side of spot so only wNOXA is needed.
        (int24 lower, int24 upper) = tokenIsToken0 ? (int24(200), int24(2000)) : (int24(-2000), int24(-200));
        (tokenId,,,) = pm.mint(
            MockNonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: seeder,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_lockAndClaimFees_routedToRecipient() public {
        uint256 tokenId = _seedPosition(1_000 ether);

        vm.prank(seeder);
        pm.safeTransferFrom(seeder, address(lock), tokenId);
        assertTrue(lock.locked());
        assertEq(lock.lockedTokenId(), tokenId);

        // Accrue fees on both sides and fund the PM to pay them out. Map the
        // per-token fees onto token0/token1 by address ordering.
        uint128 feeWnoxa = 5 ether;
        uint128 feeWeth = 3 ether;
        wnoxa.mint(address(pm), feeWnoxa);
        weth.mint(address(pm), feeWeth);
        bool tokenIsToken0 = address(wnoxa) < address(weth);
        (uint128 add0, uint128 add1) = tokenIsToken0 ? (feeWnoxa, feeWeth) : (feeWeth, feeWnoxa);
        pm.simulateFees(tokenId, add0, add1);

        lock.claimFees();
        assertEq(wnoxa.balanceOf(feeRecipient), feeWnoxa);
        assertEq(weth.balanceOf(feeRecipient), feeWeth);
    }

    function test_secondPosition_reverts_alreadyLocked() public {
        uint256 first = _seedPosition(1_000 ether);
        vm.prank(seeder);
        pm.safeTransferFrom(seeder, address(lock), first);

        // Mint a second position and try to lock it too.
        wnoxa.mint(seeder, 10 ether);
        vm.startPrank(seeder);
        wnoxa.approve(address(pm), 10 ether);
        bool tokenIsToken0 = address(wnoxa) < address(weth);
        (uint256 a0, uint256 a1) = tokenIsToken0 ? (uint256(10 ether), uint256(0)) : (uint256(0), uint256(10 ether));
        (int24 lower, int24 upper) = tokenIsToken0 ? (int24(200), int24(2000)) : (int24(-2000), int24(-200));
        (uint256 second,,,) = pm.mint(
            MockNonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? address(wnoxa) : address(weth),
                token1: tokenIsToken0 ? address(weth) : address(wnoxa),
                fee: FEE,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: seeder,
                deadline: block.timestamp
            })
        );
        vm.expectRevert(NoxaLpLock.AlreadyLocked.selector);
        pm.safeTransferFrom(seeder, address(lock), second);
        vm.stopPrank();
    }

    function test_onReceive_rejectsNonPositionManager() public {
        vm.expectRevert(NoxaLpLock.UnknownPosition.selector);
        lock.onERC721Received(address(this), address(this), 1, "");
    }

    /// A position moved in via PLAIN transferFrom never triggers onERC721Received,
    /// so it lands unlocked; the seeder recovers it with lockDirectTransfer.
    function test_lockDirectTransfer_recoversNonSafeTransfer() public {
        uint256 tokenId = _seedPosition(1_000 ether);
        vm.prank(seeder);
        pm.transferFrom(seeder, address(lock), tokenId); // no receive hook
        assertFalse(lock.locked());

        // Non-seeder cannot lock it.
        vm.expectRevert(NoxaLpLock.NotSeeder.selector);
        lock.lockDirectTransfer(tokenId);

        vm.prank(seeder);
        lock.lockDirectTransfer(tokenId);
        assertTrue(lock.locked());
        assertEq(lock.lockedTokenId(), tokenId);

        // claimFees now works and double-lock is rejected.
        vm.expectRevert(NoxaLpLock.AlreadyLocked.selector);
        vm.prank(seeder);
        lock.lockDirectTransfer(tokenId);
    }

    function test_lockDirectTransfer_rejectsUnownedAndWrongPair() public {
        uint256 tokenId = _seedPosition(1_000 ether); // still owned by seeder, not the lock
        vm.expectRevert(NoxaLpLock.UnknownPosition.selector);
        vm.prank(seeder);
        lock.lockDirectTransfer(tokenId);
    }

    function test_claimFees_reverts_whenNotLocked() public {
        vm.expectRevert(NoxaLpLock.NotLocked.selector);
        lock.claimFees();
    }

    function test_constructor_rejectsZeroConfig() public {
        vm.expectRevert(NoxaLpLock.ZeroAddress.selector);
        new NoxaLpLock(address(0), feeRecipient, seeder, address(wnoxa), address(weth), FEE);
        vm.expectRevert(NoxaLpLock.ZeroAddress.selector);
        new NoxaLpLock(address(pm), address(0), seeder, address(wnoxa), address(weth), FEE);
        vm.expectRevert(NoxaLpLock.ZeroAddress.selector);
        new NoxaLpLock(address(pm), feeRecipient, address(0), address(wnoxa), address(weth), FEE);
        vm.expectRevert(NoxaLpLock.ZeroAddress.selector);
        new NoxaLpLock(address(pm), feeRecipient, seeder, address(wnoxa), address(weth), 0);
    }

    /// @dev HARDENING: a position from anyone other than the seeder is rejected —
    /// closes the front-run hijack of the lock slot.
    function test_onReceive_rejectsNonSeeder() public {
        address attacker = makeAddr("attacker");
        (address t0, address t1) =
            address(wnoxa) < address(weth) ? (address(wnoxa), address(weth)) : (address(weth), address(wnoxa));
        v3Factory.createPool(t0, t1, FEE);
        MockUniswapV3Pool(v3Factory.getPool(t0, t1, FEE)).initialize(SQRT_1);

        // Attacker mints a correct-pair position but transfers it themselves.
        wnoxa.mint(attacker, 10 ether);
        vm.startPrank(attacker);
        wnoxa.approve(address(pm), 10 ether);
        bool tok0 = address(wnoxa) < address(weth);
        (uint256 a0, uint256 a1) = tok0 ? (uint256(10 ether), uint256(0)) : (uint256(0), uint256(10 ether));
        (int24 lo, int24 hi) = tok0 ? (int24(200), int24(2000)) : (int24(-2000), int24(-200));
        (uint256 tid,,,) = pm.mint(
            MockNonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: attacker,
                deadline: block.timestamp
            })
        );
        vm.expectRevert(NoxaLpLock.NotSeeder.selector);
        pm.safeTransferFrom(attacker, address(lock), tid);
        vm.stopPrank();
        assertFalse(lock.locked());
    }

    /// @dev HARDENING: a position for the wrong pool (wrong fee tier) is rejected
    /// even from the seeder — defense in depth against a mis-sent position.
    function test_onReceive_rejectsWrongPosition() public {
        uint24 wrongFee = 3000;
        (address t0, address t1) =
            address(wnoxa) < address(weth) ? (address(wnoxa), address(weth)) : (address(weth), address(wnoxa));
        v3Factory.createPool(t0, t1, wrongFee);
        MockUniswapV3Pool(v3Factory.getPool(t0, t1, wrongFee)).initialize(SQRT_1);

        wnoxa.mint(seeder, 10 ether);
        vm.startPrank(seeder);
        wnoxa.approve(address(pm), 10 ether);
        bool tok0 = address(wnoxa) < address(weth);
        (uint256 a0, uint256 a1) = tok0 ? (uint256(10 ether), uint256(0)) : (uint256(0), uint256(10 ether));
        (int24 lo, int24 hi) = tok0 ? (int24(200), int24(2000)) : (int24(-2000), int24(-200));
        (uint256 tid,,,) = pm.mint(
            MockNonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: wrongFee,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: seeder,
                deadline: block.timestamp
            })
        );
        vm.expectRevert(NoxaLpLock.WrongPosition.selector);
        pm.safeTransferFrom(seeder, address(lock), tid);
        vm.stopPrank();
        assertFalse(lock.locked());
    }
}
