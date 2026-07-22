// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WrappedNoxaV3 (wNOXA) — cap-native Robinhood-Chain mirror of DBK NOXA
/// @notice Successor to `WrappedNoxaV2`, addressing the on-chain-verified NOXA
/// 25,000 max-WALLET cap (docs/noxa-wallet-cap.md §3/§4.3). The source token
/// enforces a recipient-balance cap on every transfer with an owner-managed
/// exclusion list; its team is unreachable, so the community inherits those
/// tokenomics. This mirror **replicates the cap instead of bypassing it**:
///
/// - **Mirrored wallet cap.** No non-excluded address can hold more than
///   `maxWalletAmount` wNOXA (checked in `_update`, exactly like the source
///   token checks recipients in `_transfer`). Consequence: no ordinary burn
///   can exceed the cap, so every exit fits the DBK hot unlock path.
/// - **Exclusion list, ours to grant.** The source team cannot exempt our
///   lockbox from their cap, but we control this contract: the owner excludes
///   only bridge infra (the wNOXA/WETH pool, the fee burner, DEAD). The token
///   itself is always excluded — it custodies the claim escrow below.
/// - **Claim escrow — the inbound-wedge fix.** A bridge `mint` whose recipient
///   lacks cap headroom must not revert: the NOXA is already locked on DBK and
///   a reverting mint would strand the lock nonce (docs §4.3 gap). Instead the
///   mint lands in this contract and is credited to `claimable[to]`; the
///   recipient calls `claim()` once they have headroom (caller-only and
///   auto-sized, so it can be neither griefed by third-party pushes nor
///   front-run into a revert). The nonce is consumed either way — the relayer
///   never wedges and needs no code change. Escrowed tokens are real minted
///   supply, so the collateral invariant `lockbox >= totalSupply()` holds.
///
/// `mintMigration` deliberately does NOT escrow: migration is interactive (the
/// caller is the recipient), so a cap revert is retryable with a smaller amount.
///
/// Everything else — revocable minter role, hard supply cap, pause circuit
/// breaker, disabled renounce — carries over from `WrappedNoxaV2` unchanged.
contract WrappedNoxaV3 is ERC20Capped, Ownable2Step, Pausable {
    /// @notice Addresses allowed to mint (the hot relayer key; the migrator during cutover).
    mapping(address account => bool) public isMinter;

    /// @notice Inbound replay guard: DBK lock nonces already settled here (minted OR escrowed).
    mapping(uint256 srcLockNonce => bool) public processedLock;

    /// @notice Monotonic nonce for outbound (RH -> DBK) burns.
    uint256 public burnNonce;

    /// @notice Mirrored source-token cap: max balance a non-excluded address may hold.
    uint256 public maxWalletAmount;

    /// @notice Bridge-infra addresses exempt from the wallet cap (pool, burner, DEAD...).
    /// The token itself is always excluded (set in the constructor) — it holds the escrow.
    mapping(address account => bool) public isCapExcluded;

    /// @notice Escrowed bridge mints awaiting a recipient with cap headroom.
    mapping(address account => uint256) public claimable;

    /// @notice Sum of all `claimable` balances (monitoring: `balanceOf(this) >= totalEscrowed`).
    uint256 public totalEscrowed;

    event MinterSet(address indexed account, bool allowed);
    event MaxWalletSet(uint256 amount);
    event CapExclusionSet(address indexed account, bool excluded);
    /// @param srcLockNonce The `Locked` event nonce on the DBK lockbox this mint settles.
    event Minted(uint256 indexed srcLockNonce, address indexed to, uint256 amount);
    /// @notice A bridge mint whose recipient lacked cap headroom (or was this
    /// contract itself); credited to `claimable[to]`.
    event MintEscrowed(uint256 indexed srcLockNonce, address indexed to, uint256 amount);
    /// @notice Escrowed tokens released to their beneficiary.
    event EscrowClaimed(address indexed account, uint256 amount);
    /// @notice Owner recovered escrow that was parked on the token itself.
    event ParkedEscrowRescued(address indexed to, uint256 amount);
    /// @notice Emitted for a migration mint (escrow-backed, no bridge nonce consumed).
    event MigrationMinted(address indexed to, uint256 amount);
    /// @param nonce Outbound nonce; the DBK `unlock` must consume exactly this value.
    event BurnedForReturn(uint256 indexed nonce, address indexed burner, address indexed dbkRecipient, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotMinter();
    error AlreadyProcessed(uint256 srcLockNonce);
    error MaxWalletReached(address account, uint256 balance, uint256 maxWallet);
    error InvalidRecipient(address recipient);
    error InsufficientClaimable(uint256 requested, uint256 available);
    error RenounceDisabled();

    /// @param bridgeAuthority_ Cold owner (Safe) — manages minters, cap exclusions, pause.
    /// @param maxSupply_ Hard cap on wNOXA supply; set to the real DBK NOXA total supply
    ///        (e.g. 1_000_000e18). Bounds a compromised minter. Immutable (ERC20Capped).
    /// @param maxWalletAmount_ Mirrored wallet cap; set to the source token's live
    ///        `maxWalletAmount()` (25_000e18 as verified 2026-07-22). Owner-settable
    ///        later to track the source token. Must be non-zero.
    constructor(address bridgeAuthority_, uint256 maxSupply_, uint256 maxWalletAmount_)
        ERC20("Wrapped NOXA (DBK)", "wNOXA")
        ERC20Capped(maxSupply_)
        Ownable(bridgeAuthority_)
    {
        // bridgeAuthority_ == 0 rejected by Ownable; maxSupply_ == 0 rejected by ERC20Capped.
        if (maxWalletAmount_ == 0) revert ZeroAmount();
        maxWalletAmount = maxWalletAmount_;
        isCapExcluded[address(this)] = true; // escrow custody must never hit the cap
        emit MaxWalletSet(maxWalletAmount_);
        emit CapExclusionSet(address(this), true);
    }

    // -----------------------------------------------------------------------
    // Owner: roles, cap config, circuit breaker
    // -----------------------------------------------------------------------

    /// @notice Grant or revoke mint rights. Owner (Safe) only. Revoking a leaked
    /// hot key is the primary incident response short of `pause()`.
    function setMinter(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isMinter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    /// @notice Track the source token if its owner ever changes the cap. Non-zero
    /// only (an effective freeze is what `pause()` is for). Owner (Safe) only.
    function setMaxWalletAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        maxWalletAmount = amount;
        emit MaxWalletSet(amount);
    }

    /// @notice Exempt bridge infrastructure from the wallet cap — the wNOXA/WETH
    /// pool, the fee burner, DEAD. The same pattern the source token uses for its
    /// own pool. The token itself cannot be un-excluded (it custodies the escrow).
    function setCapExcluded(address account, bool excluded) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(this) && !excluded) revert InvalidRecipient(account);
        isCapExcluded[account] = excluded;
        emit CapExclusionSet(account, excluded);
    }

    /// @notice Freeze all token movement (mint/burn/transfer/claim). Owner only.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Bridge mint (relayer) + migration mint (escrow helper)
    // -----------------------------------------------------------------------

    /// @notice Settle an inbound bridge: mint wNOXA for a DBK lock. Idempotent per
    /// `srcLockNonce`. `amount` MUST equal the fee-adjusted `received` from the DBK
    /// `Locked` event. NEVER cap-reverts — the nonce is consumed on every path, so
    /// the relayer cannot wedge on any recipient:
    /// - recipient lacks cap headroom -> escrowed to `claimable[to]`;
    /// - recipient is this contract (a DBK lock naming the token as its RH
    ///   recipient — the wrapped-side equivalent of sending tokens to a token
    ///   contract) -> parked as `claimable[address(this)]`, unclaimable by third
    ///   parties, recoverable by the owner via `rescueParkedEscrow`. (v2 silently
    ///   voided such funds; reverting instead would strand the lock nonce.)
    function mint(address to, uint256 amount, uint256 srcLockNonce) external onlyMinter whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (processedLock[srcLockNonce]) revert AlreadyProcessed(srcLockNonce);
        processedLock[srcLockNonce] = true;

        if (to == address(this) || (!isCapExcluded[to] && balanceOf(to) + amount > maxWalletAmount)) {
            claimable[to] += amount;
            totalEscrowed += amount;
            _mint(address(this), amount); // supply-cap-bounded via ERC20Capped
            emit MintEscrowed(srcLockNonce, to, amount);
        } else {
            _mint(to, amount);
            emit Minted(srcLockNonce, to, amount);
        }
    }

    /// @notice Mint for a 1:1 migration from a prior wNOXA version. Used by the
    /// escrow `WNoxaMigrator`, which mints only against old wNOXA it has escrowed —
    /// so the DBK collateral backing the escrowed tokens now backs these. Carries
    /// NO bridge nonce (must not touch `processedLock`). NOT escrowed on a cap hit:
    /// migration is interactive, so the caller just retries with a smaller amount.
    function mintMigration(address to, uint256 amount) external onlyMinter whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient(to); // would orphan tokens in the escrow custodian
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount); // reverts via _update if `to` lacks cap headroom
        emit MigrationMinted(to, amount);
    }

    // -----------------------------------------------------------------------
    // Escrow claims
    // -----------------------------------------------------------------------

    /// @notice Release as much of the caller's escrowed wNOXA as their cap
    /// headroom allows: `min(claimable, maxWalletAmount - balance)`. The amount
    /// is computed at execution time — no parameter — so a claim cannot be
    /// front-run into a revert by dust-transferring the caller to their cap.
    /// Reverts if nothing is claimable or the caller is at the cap (free
    /// headroom first: transfer out, or `burnForReturn` back to DBK).
    /// Caller-only by design: a third-party push could fill the beneficiary's
    /// headroom at moments an attacker chooses (transfer/swap griefing).
    function claim() external returns (uint256 released) {
        address account = msg.sender;
        uint256 available = claimable[account];
        if (available == 0) revert ZeroAmount();

        uint256 balance = balanceOf(account);
        uint256 headroom = isCapExcluded[account]
            ? available
            : (balance >= maxWalletAmount ? 0 : maxWalletAmount - balance);
        released = available < headroom ? available : headroom;
        if (released == 0) revert ZeroAmount(); // at the cap — make headroom first

        claimable[account] = available - released;
        totalEscrowed -= released;
        _transfer(address(this), account, released); // pause + wallet cap enforced in _update
        emit EscrowClaimed(account, released);
    }

    /// @notice Recover escrow parked on the token itself — the result of a DBK
    /// lock naming this contract as its RH recipient. Owner (Safe) only; bounded
    /// to exactly the self-parked credit, so user escrow is untouchable. The
    /// wallet cap still applies to `to` unless excluded.
    function rescueParkedEscrow(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 parked = claimable[address(this)];
        if (amount > parked) revert InsufficientClaimable(amount, parked);
        claimable[address(this)] = parked - amount;
        totalEscrowed -= amount;
        _transfer(address(this), to, amount); // pause + wallet cap enforced in _update
        emit ParkedEscrowRescued(to, amount);
    }

    // -----------------------------------------------------------------------
    // Outbound
    // -----------------------------------------------------------------------

    /// @notice Begin an outbound bridge: burn the caller's wNOXA and signal the
    /// authority to release NOXA from the DBK lockbox to `dbkRecipient`. Burns are
    /// cap-exempt (to == 0), so exits work even from a wallet exactly at the cap.
    function burnForReturn(uint256 amount, address dbkRecipient) external whenNotPaused returns (uint256 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (dbkRecipient == address(0)) revert ZeroAddress();
        _burn(msg.sender, amount); // reverts on insufficient balance
        nonce = burnNonce++;
        emit BurnedForReturn(nonce, msg.sender, dbkRecipient, amount);
    }

    /// @notice Disabled — renouncing would strand DBK lockers awaiting settlement.
    /// Hand off via 2-step `transferOwnership`/`acceptOwnership`.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    /// @dev Single hook enforcing: the pause circuit-breaker (all movement), the
    /// supply cap (mint only, via ERC20Capped), the donation guard (no user
    /// transfers into the token contract — they would be unrecoverable and blur
    /// escrow accounting; escrow mints have from == 0 and pass), and the mirrored
    /// wallet cap. The cap check is PRE-state (`balanceOf(to) + value`), the exact
    /// formula the source token applies to recipients — including its self-transfer
    /// behaviour (an at-cap self-transfer reverts on both tokens). Burns to
    /// address(0) are exempt so exits always work.
    function _update(address from, address to, uint256 value) internal override(ERC20Capped) {
        _requireNotPaused();
        if (to == address(this) && from != address(0)) revert InvalidRecipient(to);
        if (to != address(0) && !isCapExcluded[to]) {
            uint256 newBalance = balanceOf(to) + value;
            if (newBalance > maxWalletAmount) revert MaxWalletReached(to, newBalance, maxWalletAmount);
        }
        super._update(from, to, value);
    }
}
