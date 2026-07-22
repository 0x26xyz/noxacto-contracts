# NOXA 25K wallet cap — bridge impact & custody design

**Status: OPEN CONSTRAINT — corroborated off-chain, NOT yet verified on-chain.**
**Nothing in this repo currently handles it.** Do not represent the bridge as
production-ready for meaningful volume until the verification in §3 is run and
(if confirmed) the design in §4 is built.

Last updated: 2026-07-22.

---

## 0. Claim status — what is actually known

| Claim | Status | Source |
| --- | --- | --- |
| NOXA (DBK, `0x6778…8dDE`) enforces a **25,000 max balance per address** | **Corroborated, unverified** | Community pages (DYOD, LaunchHood); independently raised by a third party vetting this bridge for listing. No one has read the getter on-chain yet. |
| NOXA total supply = 1,000,000 (cap = 2.5% of supply) | Corroborated | Explorer token page, multiple community sources |
| Team burned ~40% of supply (~2026-07-19) — owner ops were live days ago | Corroborated | OnchainLens; trader reports |
| NOXA team is unreachable | Reported by operator | No exemption for our lockbox can be requested |
| Wallets holding >25K exist | Reported, unqualified | If those are **contracts** (DEX pair, burn address, noxafi bridge escrow), that *supports* cap-with-exemptions rather than refuting the cap. EOA >25K would refute it. Check the holders tab. |
| This repo handles the cap | **FALSE** | `NoxaLockboxV2.lock()` custodies everything at one address; no cap logic anywhere (`grep -ri "maxWallet\|25" src/` is empty) |

## 1. Why this is critical

`NoxaLockboxV2` is a **single custody address**. If NOXA enforces a 25K max
balance on every address and our lockbox is not exempt (nobody can grant an
exemption — the team is unreachable), then:

- `lock()` starts reverting once the lockbox balance approaches **25K NOXA —
  2.5% of supply is the ceiling on total bridged collateral, forever**;
- even the wNOXA/WETH pool-seed tranche cannot be bridged in;
- the failure is silent until it happens: the transfer reverts inside NOXA's
  own code, not ours.

### Why our tests never caught it

The fork test funds wallets with `deal()` (a raw storage write that bypasses
NOXA's `_transfer` checks) and locks small amounts. A cap enforced in
`_transfer` is invisible to that methodology. Any future fork test for this
must acquire NOXA via a **real transfer** and push a balance across 25K.

## 2. Decision tree

```
Run §3 verification
├─ No active cap (limits disabled / launch-era only)
│    → No design change. Record getter output + tx simulation here. DONE.
├─ Max-TX cap only (per-transfer, not per-balance)
│    → Keep single lockbox. Split large unlocks into ≤cap releases
│      (hot path already has unlockCap; align it). Minor relayer change.
└─ Max-WALLET cap (recipient balance checked on transfer)
     → Build §4: sharded custody + mirrored cap. No shortcut exists:
       the team cannot exempt us, and a fleet is the only way to
       custody more than 25K.
```

## 3. Verification (run before any build — ~2 minutes, all free simulations)

```bash
RPC=https://rpc.dbkchain.io
NOXA=0x6778980c66bcd9A8F74D73BD1b608483c40E8DdE

# (a) Getter probe — limit tokens near-always expose one of these:
for sig in 'maxWalletAmount()(uint256)' 'maxWallet()(uint256)' \
           'maxHoldingAmount()(uint256)' '_maxWalletToken()(uint256)' \
           'maxTxAmount()(uint256)' 'limitsInEffect()(bool)'; do
  echo "== $sig"; cast call $NOXA "$sig" --rpc-url $RPC 2>/dev/null || echo "   (none)"
done

# (b) Owner status — renounced (0x0/dead) vs dark-but-live key (risk §5):
cast call $NOXA "owner()(address)" --rpc-url $RPC

# (c) Behavioral proof — simulate pushing a fresh address past 25K.
#     W = any holder with >26K from the explorer holders tab:
cast call $NOXA "transfer(address,uint256)(bool)" \
  0x000000000000000000000000000000000000d1Ff 26000ether --from $W --rpc-url $RPC
# revert => cap live on plain transfers; success => no active wallet cap

# (d) Read the verified source on scan.dbkchain.io (contract tab) for the
#     exact mechanism + exclusion mapping name (isExcludedFromLimits or similar).
```

Record the outputs in §0 when run. **Everything below assumes the max-wallet
branch confirmed.**

## 4. Cap-native custody design (build only after §3 confirms max-wallet)

Principle: **don't work around the cap — replicate it.** The team is gone; the
community inherits the tokenomics. A bridge that shards custody because the
cap binds it too, and enforces the same cap on the wrapped side, preserves
those tokenomics instead of becoming a whale's bypass vehicle.

The cap also simplifies the mechanics: no wallet can hold >25K, so **no single
`lock()` can exceed 25K** — deposits arrive in ≤25K chunks by construction.

### 4.1 `NoxaLockboxFactory` (DBK)

- Deploys `NoxaLockboxV2`-style boxes at deterministic CREATE2 addresses;
  maintains an on-chain registry (`boxes(i)`, `boxCount()`).
- One **active** box receives locks; when its balance crosses a fill threshold
  (~20K, headroom for rounding), the next box is spawned/activated.
  Bridging all ~600K circulating ⇒ ~30 boxes over the bridge's lifetime,
  spawned lazily.

### 4.2 `LockboxManager` (DBK)

- Cold-owner-owned; is the owner/unlocker-admin of every box.
- **Single global `processedBurn` map** — fixes the per-box replay-guard split
  (today each box has its own map; settling one burn across two boxes would
  otherwise create partial-failure states).
- `release(amount, to, rhBurnNonce)` settles a burn **atomically across boxes**
  (drain-oldest-first), preserving the v2 hot/cold split: rate-limited hot path
  (cap + cooldown + pause) and uncapped cold `ownerRelease`.
- Relayer changes: watch `Locked` from all registered boxes (factory registry),
  settle burns via the manager only. Collateral invariant becomes
  `Σ NOXA.balanceOf(box_i) + migrator escrow ≥ wNOXA.totalSupply()` — the
  drift circuit-breaker must sum over the registry.

### 4.3 wNOXA v3 — mirrored wallet cap

- `WrappedNoxaV2` + a **25K max-balance check in `_update`**, with an
  owner-managed exclusion list for our own infra only (LP lock, fee burner,
  migrator, pool). We control this contract, so exclusions are ours to grant —
  the same pattern NOXA itself uses for its pool.
- Consequence: no one can hold >25K wNOXA ⇒ **no burn exceeds 25K** ⇒ every
  exit fits the hot path and at most two boxes (fragmentation).
- Migration: v2 → v3 via the existing `WNoxaMigrator` escrow pattern. Bridged
  supply is currently ~zero — this is the cheapest moment to do it.

### 4.4 Testing bar

- Fork tests acquire NOXA via **real transfers** (never `deal`) and must
  include: box fill-over (lock that crosses the threshold spawns/activates the
  next box), a burn settled across two boxes atomically, replay of a settled
  nonce reverting at the manager, and invariant `Σ boxes ≥ totalSupply` under
  a fuzzed lock/burn/settle sequence.
- Simulate the cap itself in the mock NOXA (max-wallet in `_transfer`) so unit
  tests exercise the revert path the fork test proves.

## 5. Risk register (disclose these wherever the bridge is listed)

1. **Dark owner ≠ renounced owner.** If §3(b) returns a live address, an
   unreachable team still holds keys over an owner-configurable
   fee-on-transfer token. A hostile/compromised owner could push the transfer
   fee toward 100%, taxing every lock and unlock into dust. This risk applies
   to *every* NOXA holder and DEX user equally, but a custody bridge
   concentrates it and must say so. If ownership is renounced, this risk is
   dead and the cap (whatever §3 finds) is permanent.
2. **Federated custody.** Unchanged from the README trust model: the peg rests
   on the authority Safe + hot keys + monitoring. The cap redesign does not
   change the trust model; it changes only custody topology.
3. **Cap changes.** If the owner is live, the cap value itself is presumably
   owner-settable. The fleet design tolerates a raised cap (boxes just stop
   spawning as often) and a lowered one (fill threshold is config).

## 6. Listing Q&A (answers for third parties vetting the bridge)

- **Who holds the mint key?** wNOXA v2 mint is a revocable `isMinter` role held
  by the hot relayer key, granted/revoked by a cold owner Safe; supply is
  hard-capped at source supply; `pause()` is the circuit breaker; lockbox
  releases are rate-limited hot / uncapped cold-Safe. (README trust model.)
- **How does the bridge handle the 25K wallet cap?** Honest answer today: *it
  doesn't yet* — verification per §3, then the §4 sharded-custody +
  mirrored-cap design. Until then total bridged supply is capped at 25K and we
  say so. We do not claim a workaround; we replicate the cap.
- **How do you buy wNOXA without an LP pool?** You don't buy it — you bridge
  it. Lock-and-mint is 1:1 and needs no pool, no pricing, no counterparty
  liquidity. Buying wNOXA directly on Robinhood Chain is a separate optional
  layer that requires the (not-yet-seeded) wNOXA/WETH pool; nothing about the
  peg depends on it.
