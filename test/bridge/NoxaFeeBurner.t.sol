// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NoxaFeeBurner} from "../../src/bridge/NoxaFeeBurner.sol";
import {WrappedNoxa} from "../../src/bridge/WrappedNoxa.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @dev Buyback-and-burn: the burner swaps WETH fees into wNOXA, then burns ALL
/// wNOXA back to real NOXA on DBK (dead address). The MockSwapRouter swaps 1:1.
contract NoxaFeeBurnerTest is Test {
    WrappedNoxa internal wnoxa;
    MockERC20 internal weth;
    MockSwapRouter internal router;
    NoxaFeeBurner internal burner;

    address internal authority = makeAddr("authority"); // wNOXA mint owner
    address internal keeper = makeAddr("keeper");
    address internal cold = makeAddr("cold");
    uint24 internal constant FEE = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        wnoxa = new WrappedNoxa(authority);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        router = new MockSwapRouter();
        burner = new NoxaFeeBurner(address(wnoxa), address(weth), address(router), FEE, keeper, cold);
    }

    function _burn(uint256 minOut) internal returns (uint256) {
        vm.prank(keeper);
        return burner.burn(minOut);
    }

    /// @dev Mint wNOXA to `to` via the authority (the only mint path).
    function _mintWnoxa(address to, uint256 amt, uint256 nonce) internal {
        vm.prank(authority);
        wnoxa.mint(to, amt, nonce);
    }

    function test_burn_swapsWethThenBurnsAllWnoxa() public {
        // Fees that landed on the burner: 100 wNOXA + 40 WETH.
        _mintWnoxa(address(burner), 100 ether, 1);
        weth.mint(address(burner), 40 ether);
        // Router must hold wNOXA to pay out the WETH->wNOXA swap (1:1 => 40 wNOXA).
        _mintWnoxa(address(router), 40 ether, 2);

        uint256 supplyBefore = wnoxa.totalSupply();

        vm.recordLogs();
        uint256 nonce = _burn(0);

        // All wNOXA on the burner (100 fee + 40 swapped) is burned back to DBK dead.
        assertEq(wnoxa.balanceOf(address(burner)), 0);
        assertEq(weth.balanceOf(address(burner)), 0);
        assertEq(weth.balanceOf(address(router)), 40 ether); // router took the WETH
        // Supply dropped by exactly the 140 burned.
        assertEq(supplyBefore - wnoxa.totalSupply(), 140 ether);
        assertEq(nonce, 0); // first BurnedForReturn
    }

    function test_burn_wnoxaOnly_noWethSkipsSwap() public {
        _mintWnoxa(address(burner), 100 ether, 1);
        uint256 nonce = _burn(0);
        assertEq(wnoxa.balanceOf(address(burner)), 0);
        assertEq(nonce, 0);
    }

    function test_burn_reverts_whenNothingToBurn() public {
        vm.expectRevert(NoxaFeeBurner.NothingToBurn.selector);
        _burn(0);
    }

    function test_burn_respectsSlippageFloor() public {
        weth.mint(address(burner), 40 ether);
        _mintWnoxa(address(router), 40 ether, 2);
        // Demand 50 out of a 1:1 (40) swap -> router reverts.
        vm.expectRevert(MockSwapRouter.TooLittleReceived.selector);
        _burn(50 ether);
    }

    function test_burn_keeperGated() public {
        NoxaFeeBurner gated = new NoxaFeeBurner(address(wnoxa), address(weth), address(router), FEE, keeper, cold);
        _mintWnoxa(address(gated), 10 ether, 3);

        vm.expectRevert(NoxaFeeBurner.NotKeeper.selector);
        burner_burnAs(gated, makeAddr("stranger"));

        // keeper succeeds
        vm.prank(keeper);
        gated.burn(0);
        assertEq(wnoxa.balanceOf(address(gated)), 0);
    }

    function burner_burnAs(NoxaFeeBurner b, address who) internal {
        vm.prank(who);
        b.burn(0);
    }

    function test_constructor_rejectsZeroConfig() public {
        vm.expectRevert(NoxaFeeBurner.ZeroConfig.selector);
        new NoxaFeeBurner(address(0), address(weth), address(router), FEE, keeper, cold);
        vm.expectRevert(NoxaFeeBurner.ZeroConfig.selector);
        new NoxaFeeBurner(address(wnoxa), address(weth), address(router), 0, keeper, cold);
        // keeper is now mandatory (MED-2): a zero keeper is rejected.
        vm.expectRevert(NoxaFeeBurner.ZeroConfig.selector);
        new NoxaFeeBurner(address(wnoxa), address(weth), address(router), FEE, address(0), cold);
    }

    /// round-3: a leaked keeper is revocable by the cold owner (no redeploy needed).
    function test_setKeeper_rotatesLeakedKey() public {
        address newKeeper = makeAddr("newKeeper");
        // Only the owner can rotate; not the old keeper, not a stranger.
        vm.expectRevert();
        vm.prank(keeper);
        burner.setKeeper(newKeeper);

        vm.expectRevert(NoxaFeeBurner.ZeroConfig.selector);
        vm.prank(cold);
        burner.setKeeper(address(0));

        vm.prank(cold);
        burner.setKeeper(newKeeper);
        assertEq(burner.keeper(), newKeeper);

        // Old (leaked) keeper is now powerless; the new one works.
        _mintWnoxa(address(burner), 10 ether, 9);
        vm.expectRevert(NoxaFeeBurner.NotKeeper.selector);
        vm.prank(keeper);
        burner.burn(0);
        vm.prank(newKeeper);
        burner.burn(0);
        assertEq(wnoxa.balanceOf(address(burner)), 0);
    }

    function test_renounce_disabled() public {
        vm.expectRevert(NoxaFeeBurner.RenounceDisabled.selector);
        vm.prank(cold);
        burner.renounceOwnership();
    }
}
