// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

import {WrappedNoxaV2} from "../../src/bridge/WrappedNoxaV2.sol";
import {WrappedNoxaV3} from "../../src/bridge/WrappedNoxaV3.sol";
import {WNoxaMigrator} from "../../src/bridge/WNoxaMigrator.sol";

contract WrappedNoxaV3Test is Test {
    uint256 constant CAP = 1_000_000 ether; // source NOXA total supply
    uint256 constant MAX_WALLET = 25_000 ether; // mirrored source cap (verified 2026-07-22)

    WrappedNoxaV3 internal wnoxa;

    address internal owner = makeAddr("owner"); // cold Safe stand-in
    address internal minter = makeAddr("minter"); // hot relayer key
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal pool = makeAddr("pool"); // stand-in for the wNOXA/WETH pool

    function setUp() public {
        wnoxa = new WrappedNoxaV3(owner, CAP, MAX_WALLET);
        vm.prank(owner);
        wnoxa.setMinter(minter, true);
    }

    function _mint(address to, uint256 amount, uint256 nonce) internal {
        vm.prank(minter);
        wnoxa.mint(to, amount, nonce);
    }

    // =======================================================================
    // Constructor
    // =======================================================================

    function test_constructor_rejectsZeroCap() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20InvalidCap.selector, 0));
        new WrappedNoxaV3(owner, 0, MAX_WALLET);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WrappedNoxaV3(address(0), CAP, MAX_WALLET);
    }

    function test_constructor_rejectsZeroMaxWallet() public {
        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        new WrappedNoxaV3(owner, CAP, 0);
    }

    function test_constructor_setsMaxWallet_andExcludesSelf() public view {
        assertEq(wnoxa.maxWalletAmount(), MAX_WALLET);
        assertTrue(wnoxa.isCapExcluded(address(wnoxa)));
        assertFalse(wnoxa.isCapExcluded(alice));
    }

    // =======================================================================
    // Carried-over V2 behaviour
    // =======================================================================

    function test_mint_onlyMinter() public {
        vm.expectRevert(WrappedNoxaV3.NotMinter.selector);
        vm.prank(alice);
        wnoxa.mint(alice, 1 ether, 0);

        _mint(alice, 1 ether, 0);
        assertEq(wnoxa.balanceOf(alice), 1 ether);
    }

    function test_mint_replayGuard() public {
        _mint(alice, 1 ether, 7);
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.AlreadyProcessed.selector, 7));
        _mint(alice, 1 ether, 7);
    }

    function test_mint_respectsSupplyCap() public {
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, true);
        _mint(pool, CAP, 0); // excluded address can absorb the full supply
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, CAP + 1, CAP));
        _mint(alice, 1, 1);
    }

    function test_setMinter_ownerOnly_andRevoke() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wnoxa.setMinter(bob, true);

        vm.prank(owner);
        wnoxa.setMinter(minter, false);
        vm.expectRevert(WrappedNoxaV3.NotMinter.selector);
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 0);
    }

    function test_pause_freezesMintBurnTransferClaim() public {
        _mint(alice, 10 ether, 0);
        _mint(alice, MAX_WALLET, 1); // escrowed (10 + 25K > 25K)
        assertEq(wnoxa.claimable(alice), MAX_WALLET);

        vm.prank(owner);
        wnoxa.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 2);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        wnoxa.burnForReturn(1 ether, bob);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        wnoxa.claim();

        vm.prank(owner);
        wnoxa.unpause();
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether);
        assertEq(wnoxa.balanceOf(bob), 1 ether);
    }

    function test_burnForReturn_incrementsNonce() public {
        _mint(alice, 10 ether, 0);
        vm.startPrank(alice);
        uint256 n0 = wnoxa.burnForReturn(1 ether, bob);
        uint256 n1 = wnoxa.burnForReturn(1 ether, bob);
        vm.stopPrank();
        assertEq(n0, 0);
        assertEq(n1, 1);
        assertEq(wnoxa.balanceOf(alice), 8 ether);
    }

    function test_renounce_disabled() public {
        vm.expectRevert(WrappedNoxaV3.RenounceDisabled.selector);
        vm.prank(owner);
        wnoxa.renounceOwnership();
    }

    // =======================================================================
    // Mirrored wallet cap
    // =======================================================================

    function test_transfer_overCap_reverts() public {
        _mint(alice, MAX_WALLET, 0);
        _mint(bob, MAX_WALLET, 1);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedNoxaV3.MaxWalletReached.selector, bob, MAX_WALLET + 1 ether, MAX_WALLET)
        );
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether);
    }

    function test_transfer_toExactCap_succeeds() public {
        _mint(alice, 10 ether, 0);
        _mint(bob, MAX_WALLET - 1 ether, 1);
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether);
        assertEq(wnoxa.balanceOf(bob), MAX_WALLET);
    }

    function test_transfer_toExcluded_overCap_succeeds() public {
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, true);
        _mint(alice, MAX_WALLET, 0);
        _mint(bob, MAX_WALLET, 1);
        vm.prank(alice);
        wnoxa.transfer(pool, MAX_WALLET);
        vm.prank(bob);
        wnoxa.transfer(pool, MAX_WALLET);
        assertEq(wnoxa.balanceOf(pool), 2 * MAX_WALLET); // pool exceeds the cap freely
    }

    function test_burn_atCap_succeeds() public {
        _mint(alice, MAX_WALLET, 0);
        vm.prank(alice);
        wnoxa.burnForReturn(MAX_WALLET, alice); // exits are cap-exempt
        assertEq(wnoxa.balanceOf(alice), 0);
    }

    function test_selfTransfer_matchesSourceSemantics() public {
        // Source NOXA pre-checks balance+amount, so an at-cap self-transfer
        // reverts there — v3 must fingerprint identically.
        _mint(alice, MAX_WALLET, 0);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedNoxaV3.MaxWalletReached.selector, alice, MAX_WALLET + 1, MAX_WALLET)
        );
        vm.prank(alice);
        wnoxa.transfer(alice, 1);

        _mint(bob, 10 ether, 1);
        vm.prank(bob);
        wnoxa.transfer(bob, 5 ether); // below cap: self-transfer fine
        assertEq(wnoxa.balanceOf(bob), 10 ether);
    }

    function test_donation_toTokenContract_reverts() public {
        _mint(alice, 10 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.InvalidRecipient.selector, address(wnoxa)));
        vm.prank(alice);
        wnoxa.transfer(address(wnoxa), 1 ether);
    }

    // =======================================================================
    // Escrowed mints (the inbound-wedge fix)
    // =======================================================================

    function test_mint_underCap_isDirect() public {
        _mint(alice, MAX_WALLET, 0); // exactly the cap: not over, direct
        assertEq(wnoxa.balanceOf(alice), MAX_WALLET);
        assertEq(wnoxa.claimable(alice), 0);
        assertEq(wnoxa.totalEscrowed(), 0);
    }

    function test_mint_overCap_escrows() public {
        _mint(alice, 20_000 ether, 0);

        vm.expectEmit(true, true, false, true);
        emit WrappedNoxaV3.MintEscrowed(1, alice, 10_000 ether);
        _mint(alice, 10_000 ether, 1); // 20K + 10K > 25K

        assertEq(wnoxa.balanceOf(alice), 20_000 ether); // unchanged
        assertEq(wnoxa.claimable(alice), 10_000 ether);
        assertEq(wnoxa.totalEscrowed(), 10_000 ether);
        assertEq(wnoxa.balanceOf(address(wnoxa)), 10_000 ether);
        assertEq(wnoxa.totalSupply(), 30_000 ether); // escrow is real minted supply
        assertTrue(wnoxa.processedLock(1)); // nonce consumed — relayer never wedges
    }

    function test_mint_escrowed_nonceStillReplayGuarded() public {
        _mint(alice, 20_000 ether, 0);
        _mint(alice, 10_000 ether, 1); // escrowed
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.AlreadyProcessed.selector, 1));
        _mint(alice, 10_000 ether, 1);
    }

    function test_mint_toExcluded_overCap_isDirect() public {
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, true);
        _mint(pool, 100_000 ether, 0);
        assertEq(wnoxa.balanceOf(pool), 100_000 ether);
        assertEq(wnoxa.totalEscrowed(), 0);
    }

    function test_mint_toTokenContract_parksInsteadOfWedging() public {
        // A DBK lock naming the token as its RH recipient must not strand the
        // nonce (the relayer wedge) — it parks as self-credited escrow instead.
        vm.expectEmit(true, true, false, true);
        emit WrappedNoxaV3.MintEscrowed(3, address(wnoxa), 1 ether);
        _mint(address(wnoxa), 1 ether, 3);

        assertTrue(wnoxa.processedLock(3));
        assertEq(wnoxa.claimable(address(wnoxa)), 1 ether);
        assertEq(wnoxa.totalEscrowed(), 1 ether);
        assertEq(wnoxa.balanceOf(address(wnoxa)), 1 ether);
    }

    function test_rescueEscrow_selfParked_immediate_boundedToParked() public {
        _mint(address(wnoxa), 5 ether, 0); // parked (token-as-recipient)
        _mint(alice, 20_000 ether, 1);
        _mint(alice, 10_000 ether, 2); // alice's own escrow: 10K

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wnoxa.rescueEscrow(address(wnoxa), alice, 1 ether);

        // Bounded to the SELF-parked credit — user escrow is untouchable.
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.InsufficientClaimable.selector, 6 ether, 5 ether));
        vm.prank(owner);
        wnoxa.rescueEscrow(address(wnoxa), bob, 6 ether);

        // Self-parked escrow is recoverable immediately (no dormancy).
        vm.expectEmit(true, true, false, true);
        emit WrappedNoxaV3.EscrowRescued(address(wnoxa), bob, 5 ether);
        vm.prank(owner);
        wnoxa.rescueEscrow(address(wnoxa), bob, 5 ether);

        assertEq(wnoxa.balanceOf(bob), 5 ether);
        assertEq(wnoxa.claimable(address(wnoxa)), 0);
        assertEq(wnoxa.claimable(alice), 10_000 ether); // untouched
        assertEq(wnoxa.totalEscrowed(), 10_000 ether);
        assertEq(wnoxa.balanceOf(address(wnoxa)), 10_000 ether);
    }

    function test_rescueEscrow_realAccount_requiresDormancy() public {
        // A contract/exchange address that can't call claim(); escrow over cap.
        _mint(alice, 20_000 ether, 1);
        _mint(alice, 10_000 ether, 2); // 10K escrowed to alice
        assertEq(wnoxa.claimableSince(alice), block.timestamp);

        // Before dormancy elapses the owner cannot touch a real account's escrow.
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.EscrowNotDormant.selector, alice));
        vm.prank(owner);
        wnoxa.rescueEscrow(alice, bob, 1 ether);

        vm.warp(block.timestamp + wnoxa.ESCROW_RESCUE_DELAY());
        vm.prank(owner);
        wnoxa.rescueEscrow(alice, bob, 10_000 ether); // dormant — recoverable to a recovery address
        assertEq(wnoxa.balanceOf(bob), 10_000 ether);
        assertEq(wnoxa.claimable(alice), 0);
        assertEq(wnoxa.claimableSince(alice), 0); // clock reset on full drain
    }

    /// round-4: a partial claim is activity and resets the dormancy clock, so the
    /// owner cannot rescue the remainder right after the recipient just claimed.
    function test_rescueEscrow_partialClaimResetsDormancy() public {
        _mint(alice, 20_000 ether, 1); // balance 20K -> headroom is only 5K
        _mint(alice, 30_000 ether, 2); // 30K escrowed (> headroom), clock starts here
        vm.warp(block.timestamp + wnoxa.ESCROW_RESCUE_DELAY() - 1);

        // Alice claims a tranche: released clamps to the 5K headroom, 25K remains.
        vm.prank(alice);
        uint256 released = wnoxa.claim();
        assertEq(released, 5_000 ether);
        assertEq(wnoxa.claimable(alice), 25_000 ether); // still escrowed
        assertEq(wnoxa.claimableSince(alice), block.timestamp); // clock RESET by the claim

        // Owner cannot rescue right after the claim, even though >7 days passed
        // since the original credit — the claim restarted dormancy.
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.EscrowNotDormant.selector, alice));
        vm.prank(owner);
        wnoxa.rescueEscrow(alice, bob, 1 ether);

        // Only after a fresh full dormancy window with no activity does rescue open.
        vm.warp(block.timestamp + wnoxa.ESCROW_RESCUE_DELAY());
        uint256 rem = wnoxa.claimable(alice);
        vm.prank(owner);
        wnoxa.rescueEscrow(alice, bob, rem);
        assertGt(wnoxa.balanceOf(bob), 0);
    }

    function test_rescueEscrow_zeroGuards() public {
        _mint(address(wnoxa), 1 ether, 0);
        vm.startPrank(owner);
        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        wnoxa.rescueEscrow(address(wnoxa), address(0), 1 ether);
        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        wnoxa.rescueEscrow(address(wnoxa), bob, 0);
        vm.stopPrank();
    }

    function test_mintMigration_toTokenContract_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.InvalidRecipient.selector, address(wnoxa)));
        vm.prank(minter);
        wnoxa.mintMigration(address(wnoxa), 1 ether);
    }

    function test_mint_escrow_supplyCapReverts() public {
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, true);
        _mint(pool, CAP - 10 ether, 0);
        _mint(alice, 10 ether, 1);
        // alice is at 10, supply at CAP. An escrowing mint must still hit the supply cap.
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, CAP + MAX_WALLET, CAP));
        _mint(alice, MAX_WALLET, 2);
    }

    // =======================================================================
    // Claims
    // =======================================================================

    function _escrowForAlice(uint256 preBalance, uint256 escrowed) internal {
        if (preBalance != 0) _mint(alice, preBalance, 100);
        _mint(alice, escrowed, 101); // preBalance + escrowed must exceed MAX_WALLET
        assertEq(wnoxa.claimable(alice), escrowed);
    }

    function test_claim_atCap_noOpUntilHeadroomMade() public {
        _escrowForAlice(MAX_WALLET, 10_000 ether);

        // No headroom yet — claim() is a safe no-op (returns 0, does NOT revert; MED-4).
        vm.prank(alice);
        assertEq(wnoxa.claim(), 0);
        assertEq(wnoxa.claimable(alice), 10_000 ether); // untouched

        // Exit 10K to DBK — burns are cap-exempt — then the claim fits exactly.
        vm.prank(alice);
        wnoxa.burnForReturn(10_000 ether, alice);
        vm.expectEmit(true, false, false, true);
        emit WrappedNoxaV3.EscrowClaimed(alice, 10_000 ether);
        vm.prank(alice);
        uint256 released = wnoxa.claim();

        assertEq(released, 10_000 ether);
        assertEq(wnoxa.balanceOf(alice), MAX_WALLET);
        assertEq(wnoxa.claimable(alice), 0);
        assertEq(wnoxa.totalEscrowed(), 0);
        assertEq(wnoxa.balanceOf(address(wnoxa)), 0);
    }

    function test_claim_clampsToHeadroom() public {
        _escrowForAlice(20_000 ether, 10_000 ether);
        vm.prank(alice);
        uint256 released = wnoxa.claim(); // headroom is 5K of the 10K claimable
        assertEq(released, 5_000 ether);
        assertEq(wnoxa.balanceOf(alice), MAX_WALLET);
        assertEq(wnoxa.claimable(alice), 5_000 ether);
        assertEq(wnoxa.totalEscrowed(), 5_000 ether);
    }

    function test_claim_immuneToDustFrontRunning() public {
        _escrowForAlice(21_000 ether, 5_000 ether); // 21K + 5K > 25K -> escrowed
        // Attacker dust-gifts alice right before her claim; an exact-amount
        // claim would fail — auto-sizing just clamps and succeeds.
        _mint(bob, 10 ether, 200);
        vm.prank(bob);
        wnoxa.transfer(alice, 1);
        vm.prank(alice);
        uint256 released = wnoxa.claim(); // headroom = 4K - 1 wei of the 5K
        assertEq(released, 4_000 ether - 1);
        assertEq(wnoxa.balanceOf(alice), MAX_WALLET);
        assertEq(wnoxa.claimable(alice), 1_000 ether + 1);
    }

    function test_claim_nothingClaimable_isNoOp() public {
        vm.prank(alice);
        assertEq(wnoxa.claim(), 0); // no escrow -> no-op, not a revert (MED-4)
    }

    function test_claim_afterCapRaise() public {
        _escrowForAlice(MAX_WALLET, 10_000 ether);
        vm.prank(owner);
        wnoxa.setMaxWalletAmount(50_000 ether); // source token raised its cap
        vm.prank(alice);
        wnoxa.claim();
        assertEq(wnoxa.balanceOf(alice), 35_000 ether);
    }

    function test_claim_excludedAccount_releasesAll() public {
        _escrowForAlice(20_000 ether, 10_000 ether);
        vm.prank(owner);
        wnoxa.setCapExcluded(alice, true); // e.g. alice becomes bridge infra
        vm.prank(alice);
        uint256 released = wnoxa.claim();
        assertEq(released, 10_000 ether);
        assertEq(wnoxa.balanceOf(alice), 30_000 ether);
    }

    // =======================================================================
    // Owner cap config
    // =======================================================================

    function test_setMaxWalletAmount_ownerOnly_nonZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wnoxa.setMaxWalletAmount(1 ether);

        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        vm.prank(owner);
        wnoxa.setMaxWalletAmount(0);

        vm.prank(owner);
        wnoxa.setMaxWalletAmount(30_000 ether);
        assertEq(wnoxa.maxWalletAmount(), 30_000 ether);
    }

    function test_setCapExcluded_ownerOnly_andGuards() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wnoxa.setCapExcluded(pool, true);

        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        vm.prank(owner);
        wnoxa.setCapExcluded(address(0), true);

        // The escrow custodian can never be re-capped.
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV3.InvalidRecipient.selector, address(wnoxa)));
        vm.prank(owner);
        wnoxa.setCapExcluded(address(wnoxa), false);
    }

    function test_unexclude_overCapHolder_blocksInboundNotOutbound() public {
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, true);
        _mint(pool, 100_000 ether, 0);
        vm.prank(owner);
        wnoxa.setCapExcluded(pool, false); // now over-cap and unexcluded

        // Inbound to the over-cap holder reverts (even 1 wei)...
        _mint(alice, 1 ether, 1);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedNoxaV3.MaxWalletReached.selector, pool, 100_000 ether + 1, MAX_WALLET)
        );
        vm.prank(alice);
        wnoxa.transfer(pool, 1);

        // ...but outbound still works: the balance can always drain down.
        vm.prank(pool);
        wnoxa.transfer(alice, 1_000 ether);
        assertEq(wnoxa.balanceOf(alice), 1_001 ether);
    }

    // =======================================================================
    // mintMigration + v2 -> v3 migration
    // =======================================================================

    function _deployMigration() internal returns (WrappedNoxaV2 oldT, WNoxaMigrator mig) {
        oldT = new WrappedNoxaV2(owner, CAP);
        mig = new WNoxaMigrator(address(oldT), address(wnoxa), owner);
        vm.startPrank(owner);
        oldT.setMinter(minter, true);
        wnoxa.setMinter(address(mig), true);
        vm.stopPrank();
    }

    function test_migrate_v2ToV3_1to1() public {
        (WrappedNoxaV2 oldT, WNoxaMigrator mig) = _deployMigration();
        vm.prank(minter);
        oldT.mint(alice, 100 ether, 0);

        vm.startPrank(alice);
        oldT.approve(address(mig), 100 ether);
        uint256 minted = mig.migrate(100 ether);
        vm.stopPrank();

        assertEq(minted, 100 ether);
        assertEq(wnoxa.balanceOf(alice), 100 ether);
        assertEq(oldT.balanceOf(address(mig)), 100 ether); // escrowed, not burned
        assertEq(mig.totalMigrated(), 100 ether);
    }

    function test_migrate_overCap_revertsAndRetriesSmaller() public {
        (WrappedNoxaV2 oldT, WNoxaMigrator mig) = _deployMigration();
        vm.prank(minter);
        oldT.mint(alice, 30_000 ether, 0); // v2 has no wallet cap

        vm.startPrank(alice);
        oldT.approve(address(mig), 30_000 ether);
        // Interactive path: cap revert, NOT escrow — the caller retries smaller.
        vm.expectRevert(
            abi.encodeWithSelector(WrappedNoxaV3.MaxWalletReached.selector, alice, 30_000 ether, MAX_WALLET)
        );
        mig.migrate(30_000 ether);

        mig.migrate(20_000 ether); // fits
        vm.stopPrank();
        assertEq(wnoxa.balanceOf(alice), 20_000 ether);
        assertEq(oldT.balanceOf(alice), 10_000 ether);
    }

    // =======================================================================
    // Zero-guard revert paths
    // =======================================================================

    function test_zeroGuards() public {
        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        vm.prank(owner);
        wnoxa.setMinter(address(0), true);

        vm.startPrank(minter);
        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        wnoxa.mint(address(0), 1 ether, 0);
        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        wnoxa.mint(alice, 0, 0);
        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        wnoxa.mintMigration(address(0), 1 ether);
        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        wnoxa.mintMigration(alice, 0);
        vm.stopPrank();

        _mint(alice, 1 ether, 0);
        vm.startPrank(alice);
        vm.expectRevert(WrappedNoxaV3.ZeroAmount.selector);
        wnoxa.burnForReturn(0, alice);
        vm.expectRevert(WrappedNoxaV3.ZeroAddress.selector);
        wnoxa.burnForReturn(1 ether, address(0));
        vm.stopPrank();
    }

    // =======================================================================
    // Fuzz
    // =======================================================================

    /// @dev The wedge fix, fuzzed: for ANY pre-balance and mint size, a bridge
    /// mint either lands or escrows — it never reverts on the wallet cap, and the
    /// nonce is always consumed.
    function testFuzz_mint_neverWedgesOnWalletCap(uint256 pre, uint256 amount) public {
        pre = bound(pre, 0, MAX_WALLET); // a non-excluded wallet can never exceed the cap
        amount = bound(amount, 1, CAP - pre); // stay inside the supply cap
        if (pre != 0) _mint(alice, pre, 0);

        _mint(alice, amount, 1);
        assertTrue(wnoxa.processedLock(1));

        if (pre + amount > MAX_WALLET) {
            assertEq(wnoxa.balanceOf(alice), pre);
            assertEq(wnoxa.claimable(alice), amount);
            assertEq(wnoxa.balanceOf(address(wnoxa)), amount);
        } else {
            assertEq(wnoxa.balanceOf(alice), pre + amount);
            assertEq(wnoxa.claimable(alice), 0);
        }
        assertEq(wnoxa.totalSupply(), pre + amount); // escrow or not, supply == locked collateral
    }

    /// @dev No transfer may leave a non-excluded recipient above the cap; any
    /// transfer that keeps it at or below must succeed.
    function testFuzz_transfer_capBoundary(uint256 toPre, uint256 amount) public {
        toPre = bound(toPre, 0, MAX_WALLET);
        amount = bound(amount, 1, MAX_WALLET);
        _mint(alice, MAX_WALLET, 0);
        if (toPre != 0) _mint(bob, toPre, 1);

        if (toPre + amount > MAX_WALLET) {
            vm.expectRevert(
                abi.encodeWithSelector(WrappedNoxaV3.MaxWalletReached.selector, bob, toPre + amount, MAX_WALLET)
            );
            vm.prank(alice);
            wnoxa.transfer(bob, amount);
        } else {
            vm.prank(alice);
            wnoxa.transfer(bob, amount);
            assertEq(wnoxa.balanceOf(bob), toPre + amount);
        }
    }
}
