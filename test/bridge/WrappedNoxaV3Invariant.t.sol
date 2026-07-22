// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WrappedNoxaV3} from "../../src/bridge/WrappedNoxaV3.sol";

/// @dev Drives WrappedNoxaV3 through random mint/escrow/claim/transfer/burn
/// sequences. Preconditions are guarded so calls succeed — every action a real
/// actor could take is exercised, and the invariants below must survive all of it.
contract WNoxaV3Handler is Test {
    uint256 constant CAP = 1_000_000 ether;
    uint256 constant MAX_WALLET = 25_000 ether;

    WrappedNoxaV3 public immutable wnoxa;
    address public immutable minter;
    address public immutable owner;

    address[] public actors;
    uint256 public nextLockNonce;

    constructor(WrappedNoxaV3 wnoxa_, address minter_, address owner_) {
        wnoxa = wnoxa_;
        minter = minter_;
        owner = owner_;
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Bridge mint to a random actor — lands or escrows, must never wedge.
    function bridgeMint(uint256 actorSeed, uint256 amount) external {
        uint256 supplyHeadroom = CAP - wnoxa.totalSupply();
        if (supplyHeadroom == 0) return;
        amount = bound(amount, 1, supplyHeadroom > 50_000 ether ? 50_000 ether : supplyHeadroom);
        vm.prank(minter);
        wnoxa.mint(_actor(actorSeed), amount, nextLockNonce++);
    }

    /// @dev Claim — auto-sized by the contract; skip only when it would revert.
    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 claimable = wnoxa.claimable(actor);
        uint256 headroom = MAX_WALLET - wnoxa.balanceOf(actor);
        if (claimable == 0 || headroom == 0) return;
        vm.prank(actor);
        wnoxa.claim();
    }

    /// @dev A DBK lock naming the token as its RH recipient — parks as escrow.
    function parkMint(uint256 amount) external {
        uint256 supplyHeadroom = CAP - wnoxa.totalSupply();
        if (supplyHeadroom == 0) return;
        amount = bound(amount, 1, supplyHeadroom > 1_000 ether ? 1_000 ether : supplyHeadroom);
        vm.prank(minter);
        wnoxa.mint(address(wnoxa), amount, nextLockNonce++);
    }

    /// @dev Owner recovers parked escrow to an actor with headroom.
    function rescueParked(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 parked = wnoxa.claimable(address(wnoxa));
        uint256 headroom = MAX_WALLET - wnoxa.balanceOf(actor);
        uint256 max = parked < headroom ? parked : headroom;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(owner);
        wnoxa.rescueEscrow(address(wnoxa), actor, amount);
    }

    /// @dev Peer transfer bounded by sender balance and recipient headroom.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 bal = wnoxa.balanceOf(from);
        uint256 headroom = MAX_WALLET - wnoxa.balanceOf(to);
        uint256 max = bal < headroom ? bal : headroom;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(from);
        wnoxa.transfer(to, amount);
    }

    /// @dev Outbound exit — cap-exempt, always available up to the balance.
    function burnForReturn(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = wnoxa.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        wnoxa.burnForReturn(amount, actor);
    }
}

contract WrappedNoxaV3InvariantTest is Test {
    uint256 constant CAP = 1_000_000 ether;
    uint256 constant MAX_WALLET = 25_000 ether;

    WrappedNoxaV3 internal wnoxa;
    WNoxaV3Handler internal handler;
    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");

    function setUp() public {
        wnoxa = new WrappedNoxaV3(owner, CAP, MAX_WALLET);
        vm.prank(owner);
        wnoxa.setMinter(minter, true);
        handler = new WNoxaV3Handler(wnoxa, minter, owner);
        targetContract(address(handler));
    }

    /// @dev Escrow solvency: the token contract holds EXACTLY the escrowed sum —
    /// nothing else can flow in (donation guard) or out (claims only).
    function invariant_escrowExactlyBacked() public view {
        assertEq(wnoxa.balanceOf(address(wnoxa)), wnoxa.totalEscrowed());
    }

    /// @dev totalEscrowed is the sum of individual claims (incl. the self-parked
    /// credit from token-as-recipient mints) — no orphaned credit.
    function invariant_totalEscrowedEqualsSumOfClaimables() public view {
        uint256 sum = wnoxa.claimable(address(wnoxa));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += wnoxa.claimable(handler.actors(i));
        }
        assertEq(sum, wnoxa.totalEscrowed());
    }

    /// @dev The mirrored cap holds for every non-excluded holder at all times.
    function invariant_noActorAboveCap() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            assertLe(wnoxa.balanceOf(handler.actors(i)), MAX_WALLET);
        }
    }

    /// @dev Conservation: all supply sits with actors or in escrow, within the cap.
    function invariant_supplyConserved() public view {
        uint256 sum = wnoxa.balanceOf(address(wnoxa));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += wnoxa.balanceOf(handler.actors(i));
        }
        assertEq(sum, wnoxa.totalSupply());
        assertLe(wnoxa.totalSupply(), CAP);
    }
}
