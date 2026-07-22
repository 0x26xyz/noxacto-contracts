# NOXA 25K wallet cap — bridge impact & custody design

**Status: CONSTRAINT VERIFIED ON-CHAIN (§3, 2026-07-22). Max-WALLET branch
confirmed; §4 is operative. wNOXA v3 (§4.3, mirrored cap + claim escrow) is
BUILT — `src/bridge/WrappedNoxaV3.sol` — and awaiting deployment. The lockbox
fleet (§4.1/§4.2) is designed but deliberately DEFERRED: one box's ~25K
headroom already fits the largest possible EOA bridger; build it at whale #2.**

Until the fleet ships, total bridged collateral is capped ~25K NOXA and we say
so wherever the bridge is listed.

Last updated: 2026-07-22.

---

## 0. Claim status — what is actually known

| Claim | Status | Source |
| --- | --- | --- |
| NOXA (DBK, `0x6778…8dDE`) enforces a **25,000 max balance per address** | **VERIFIED on-chain 2026-07-22** | §3 record below: getter + behavioral simulation + verified source |
| NOXA total supply = 1,000,000 (cap = 2.5% of supply) | Verified | Explorer + `totalSupply()` |
| Team burned ~40% of supply (~2026-07-19) | Corroborated | OnchainLens; DEAD (excluded) holds 400K |
| NOXA team is unreachable | Reported by operator | No exemption for our lockbox can be requested |
| Wallets holding >25K exist | **Explained — all excluded contracts** | 85.8K = the live NOXA/WETH V3 pool (excluded); 50K + 50K = owner-excluded contracts (staking/farms/treasury); largest EOA holds 20,494. Supports the cap, does not refute it. |
| This repo handles the cap | **wNOXA v3 built; fleet deferred** | `WrappedNoxaV3` mirrors the cap + escrows wedged inbound mints; custody is still one lockbox (~25K ceiling) until §4.1/§4.2 ship |

## 1. Why this is critical

`NoxaLockboxV2` is a **single custody address**. NOXA enforces a 25K max
balance on every non-excluded address and our lockbox is not exempt (nobody can
grant an exemption — the team is unreachable), so:

- `lock()` starts reverting once the lockbox balance approaches **25K NOXA —
  2.5% of supply is the ceiling on total bridged collateral** until the §4
  fleet ships;
- the failure is silent until it happens: the transfer reverts inside NOXA's
  own code, not ours.

### Why our tests never caught it

The fork test funds wallets with `deal()` (a raw storage write that bypasses
NOXA's `_transfer` checks) and locks small amounts. A cap enforced in
`_transfer` is invisible to that methodology. Any future fork test for this
must acquire NOXA via a **real transfer** and push a balance across 25K.

## 2. Decision tree

Resolved 2026-07-22: §3 confirmed the **max-WALLET branch** → build §4.
Decision on sequencing: **§4.3 (wNOXA v3) first** — bridged supply ~20.75 makes
this the cheapest migration moment — **fleet (§4.1/§4.2) deferred** until
demand exceeds one box's headroom.

## 3. Verification — RUN 2026-07-22, all via `cast` against `https://rpc.dbkchain.io`

- (a) `maxWalletAmount()` = 25,000e18; `maxWalletEnabled()` = true; no max-tx
  getter (24K/26K simulation also proves no max-TX).
- (b) `owner()` = `0xd46A813fA02A4937f580D1D39B08fa862bF50660` — live EOA,
  **not renounced**, team unreachable (risk §5.1 applies).
- (c) Behavioral proof: transfer of 26,000 from excluded holder
  `0xd46526…c070` to a fresh EOA reverts `0x79d1857a` = `MaxWalletReached()`;
  24,000 succeeds → recipient-balance max-WALLET cap, not max-tx.
- (d) Verified source: check is `maxWalletEnabled &&
  !isExcludedFromMaxWallet(recipient) && balanceOf(recipient) + amount >
  maxWalletAmount`; exclusions = owner / token / DEAD / `_isNoxaPair` /
  owner-set list; owner powers: `excludeFromMaxWallet`, `setMaxWalletEnabled`,
  `setMaxWalletAmount` (floor 0.1% of supply). Fees are **pair-only**
  (`isBuy`/`isSell` = `isNoxaPair(sender/recipient)`), currently 0, and
  **hard-bounded at `MAX_FEE` = 1000/1e4 = 10%** (setters revert `FeeTooHigh`).
  Plain transfers (lock/unlock) are untaxed.
- Exclusions checked: v1 lockbox `0x7Bedd4…` = false, v2 lockbox `0x597E9c…` =
  false → ceiling binds; v2 lockbox holds ~20.75, headroom ~24,979.
- **NOXA's live market found:** NOXA/WETH 1% Uniswap V3 pool on DBK
  `0x00b9B5096dcB4AaD445E78C5A264DFe472867653` (~19 WETH + ~86K NOXA,
  4,611 NOXA/WETH, tick 84366; token0 = WETH predeploy `0x4200…0006`).
  Owner-excluded from the cap, NOT flagged `isNoxaPair` (DEX trades pay no
  token fee). This pool is the **price anchor** for any wrapped-side pool —
  read its `slot0` at seed time; both chains order WETH = token0 so the
  tick/sqrtPrice carries over directly. "How do you price wNOXA" now has a
  market answer. Depth ceiling while the cap binds: 25K NOXA ≈ 5.4 WETH.

## 4. Cap-native custody design (max-wallet branch confirmed — operative)

Principle: **don't work around the cap — replicate it.** The team is gone; the
community inherits the tokenomics. A bridge that shards custody because the
cap binds it too, and enforces the same cap on the wrapped side, preserves
those tokenomics instead of becoming a whale's bypass vehicle.

The cap also simplifies the mechanics: no wallet can hold >25K, so **no single
`lock()` can exceed 25K** — deposits arrive in ≤25K chunks by construction.

**BUILT 2026-07-22 (`src/bridge/NoxaLockboxManager.sol` + `NoxaShardedBox.sol`).**
Single manager, one global lock nonce + global `processedBurn`, lazy shard
spawning (each ≤ cap), oldest-first cross-shard drain with a bounded cursor,
V3's dual leaky-bucket hot/cold split, `totalCollateral()` for the drift breaker.
Hardened through two adversarial passes: `lock` pulls NOXA STRAIGHT into a shard
(the manager never custodies, so stray NOXA can't cap-brick inbound, and
`received` is a single-hop delta so RH never over-mints); poisoned spawn
addresses are absorbed as collateral (`spawnBoxes` owner escape hatch);
`ownerDrainShard` recovers NOXA stray-sent to a retired shard; `rescueBoxToken`
for non-NOXA. Relayer needs `LOCKBOX_IS_MANAGER=true` (reads `totalCollateral()`);
UI likewise. NOT yet deployed. Known residual: the outbound recipient-cap wedge
(a DBK recipient already near their own 25K cap) is still relayer policy — the
relayer must skip-and-continue so one wedged burn doesn't head-of-line block.

**Bridge burn fee (added 2026-07-22).** `lock` skims `bridgeFeeBps` of every
custodied deposit (launch: 100 = 1%; owner-tunable, hard ceiling
`MAX_BRIDGE_FEE_BPS` = 2%; 0 disables) from the shard straight to DEAD on DBK —
real NOXA leaves circulation in the same transaction. This is the community
buyback-and-burn, contract-enforced on BRIDGE volume; the LP-fee `NoxaFeeBurner`
flywheel (which only earns on pool TRADING volume) remains as a complement.
`Locked` emits the NET amount, so the relayer mints exactly the vaulted
collateral and the peg invariant is unchanged. DEAD is cap-excluded on the
source token (verified §1 — it holds the team's 400K burn), so the skim cannot
cap-revert; if it ever did, `setBridgeFeeBps(0)` restores `lock` without a
redeploy. Relayer/UI: quote the net amount ("you will receive X on RH, 1% burn
fee") — the `Locked` event needs no decoder change.

### 4.1 `NoxaLockboxFactory` (DBK) — SUPERSEDED by NoxaLockboxManager (built)

- Deploys `NoxaLockboxV2`-style boxes at deterministic CREATE2 addresses;
  maintains an on-chain registry (`boxes(i)`, `boxCount()`).
- One **active** box receives locks; when its balance crosses a fill threshold
  (~20K, headroom for rounding), the next box is spawned/activated.
  Bridging all ~600K circulating ⇒ ~30 boxes over the bridge's lifetime,
  spawned lazily.

### 4.2 `LockboxManager` (DBK) — DEFERRED

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

### 4.3 wNOXA v3 — mirrored wallet cap — **BUILT (`src/bridge/WrappedNoxaV3.sol`)**

- `WrappedNoxaV2` + a **max-balance check in `_update`** (post-state recipient
  balance vs `maxWalletAmount`, initialized 25_000e18, owner-settable to track
  the source token), with an owner-managed exclusion list for our own infra
  only (the wNOXA/WETH pool, the fee burner, DEAD). We control this contract,
  so exclusions are ours to grant — the same pattern NOXA itself uses for its
  pool. The token contract itself is permanently excluded (it custodies the
  escrow below). Burns (`to == address(0)`) are cap-exempt, so exits always
  work even from a wallet exactly at the cap.
- **Inbound-wedge fix — claim escrow.** The design gap: a mirrored cap can
  wedge INBOUND mints (recipient near 25K wNOXA → mint reverts → the DBK lock
  nonce sticks, with the NOXA already locked). Resolution: `mint()` never
  cap-reverts — if the recipient lacks headroom the tokens are minted to the
  token contract and credited to `claimable[to]`; the recipient calls
  `claim()` once headroom exists. The nonce is consumed either way; **the
  relayer needs zero code change**. Escrowed tokens are real minted supply,
  so the collateral invariant `lockbox ≥ totalSupply()` is unchanged. A
  donation guard blocks user transfers into the token contract, keeping
  `balanceOf(token) == totalEscrowed` exact (invariant-tested).
  `claim()` is deliberately **caller-only and auto-sized**
  (`min(claimable, headroom)`, computed at execution time): a permissionless
  `claimFor` would let an attacker fill a victim's cap headroom at chosen
  moments (transfer/swap griefing), and an exact-amount claim could be
  front-run into a revert by dust-gifting the claimer to their cap
  (adversarial-review findings, 2026-07-22).
- **Token-as-recipient locks park, never wedge.** A DBK lock naming the wNOXA
  contract itself as its RH recipient (the wrapped-side "tokens sent to the
  token contract" footgun — v2 silently voided these) would either wedge the
  relayer (if `mint` reverted) or corrupt escrow accounting (if minted
  directly). v3 parks such mints as `claimable[address(this)]`: accounted,
  monitorable, unclaimable by third parties, and recoverable by the owner via
  `rescueParkedEscrow(to, amount)` — which is bounded to exactly the
  self-parked credit, so user escrow is untouchable.
- The cap check in `_update` is **pre-state** (`balanceOf(to) + value`), the
  exact formula the source token applies — including self-transfer semantics
  (an at-cap self-transfer reverts on both tokens), so cap-behaviour
  fingerprinting cannot distinguish them.
- `mintMigration` deliberately does NOT escrow: migration is interactive (the
  caller is the recipient), so a cap revert is retryable with a smaller amount.
  It rejects `to == address(this)` (a rogue/buggy minter could otherwise
  orphan unaccounted tokens in the escrow custodian).
- **Outbound wedge (DBK side) — inherent, documented, NOT fixed by v3.** The
  mirrored cap guarantees no burn exceeds 25K, but it cannot guarantee the
  DBK **recipient** has source-token headroom: a holder of 24K NOXA on DBK who
  redeems 5K wNOXA produces an `unlock` whose NOXA transfer reverts inside the
  source token. The burn nonce stays UNCONSUMED (retryable — `_release` marks
  `processedBurn` only on success), so nothing is lost: the exit settles once
  the recipient frees DBK headroom, or the owner settles it to an alternative
  recipient via `ownerUnlock` (the `to` parameter is not bound on-chain to the
  burn's `dbkRecipient`; the relayer binds it by policy, the cold path may
  redirect with the burner's consent). **Relayer policy: unlock failures must
  not head-of-line block other nonces.** The §4.2 manager formalizes this.
- Consequence: no non-excluded wallet can hold >25K wNOXA ⇒ no ordinary burn
  exceeds 25K ⇒ every exit fits the hot path and at most two boxes
  (fragmentation) once the fleet ships.
- Migration: v2 → v3 via a fresh instance of the existing `WNoxaMigrator`
  (parameterised by old/new — no rewrite). Bridged supply is ~20.75 — this is
  the cheapest moment to do it.
- Ops scripts: `script/bridge/DeployWrappedNoxaV3.s.sol` (deploy),
  `script/bridge/ConfigureWNoxaV3.s.sol` (minters + exclusions),
  `script/bridge/DeployWNoxaMigrator.s.sol` with `OLD_WNOXA` = v2.
  **Ordering requirement:** the wNOXA/WETH pool must be `setCapExcluded`
  as soon as it is created (its balance crossing 25K would otherwise start
  reverting swaps), and the `NoxaFeeBurner` must be excluded before fees
  accrue. The relayer/noxacto UI "arrived" check polls destination balance —
  an escrowed mint settles the nonce without moving the balance, so the UI
  needs a claimable surface before v3 sees real cap-edge traffic.

### 4.4 Testing bar

- **Review status (3 passes, adversarially verified):** round-1 HIGH-1/2/3 →
  `NoxaLockboxV3` (per-version box). Round-2 (lockbox) NEW-1 tumbling window,
  NEW-2 nonce-count griefing, NEW-3 batched recovery → dual leaky buckets +
  batch/range `clearProcessedBurn*` + bucket-reset-on-rotation + cap-lower
  clamp. Round-1 wNOXA mediums → MED-1 `rescueEscrow` (dormancy-gated,
  clock resets per credit), MED-3 documented (escrow uncapped-but-parked,
  withdrawal cap-limited), MED-4 `claim()` is a no-op (returns 0) at the cap.
  MED-2 → `NoxaFeeBurner` keeper mandatory AND rotatable (`setKeeper`, cold
  owner). `NoxaLpLock.lockDirectTransfer` recovers a non-safe-transferred
  position. Each pass verified by a multi-agent adversarial workflow; the sole
  surviving round-3 finding (immutable keeper) is fixed.
- v3 unit+fuzz+invariant suite: `test/bridge/WrappedNoxaV3.t.sol` (cap
  boundaries, escrow/claim flows incl. dust-front-running immunity and
  parked-escrow rescue, migration cap-revert, source-parity self-transfer,
  zero guards, never-wedge fuzz) and `test/bridge/WrappedNoxaV3Invariant.t.sol`
  (escrow solvency `balanceOf(token) == totalEscrowed`, Σ claimable ==
  totalEscrowed incl. the parked credit, no actor above cap, supply
  conservation; 256 runs × 64 depth). Coverage: 96.2% lines / 100% branches /
  100% funcs. Adversarially reviewed 2026-07-22 (5 lenses × 3-vote verify):
  confirmed findings fixed (token-as-recipient parking, `mintMigration`
  guard, claimFor removal, pre-state cap parity); outbound DBK wedge
  documented above.
- Fleet tests (when built) must acquire NOXA via **real transfers** (never
  `deal`) and include: box fill-over, a burn settled across two boxes
  atomically, replay of a settled nonce reverting at the manager, and the
  invariant `Σ boxes ≥ totalSupply` under a fuzzed lock/burn/settle sequence.
- Simulate the cap itself in the mock NOXA (max-wallet in `_transfer`) so unit
  tests exercise the revert path the fork test proves.

## 5. Risk register (disclose these wherever the bridge is listed)

1. **Dark owner ≠ renounced owner.** §3(b) confirmed a live owner EOA behind an
   unreachable team. Owner powers over the token are real but **bounded**: the
   transfer fee is hard-capped at `MAX_FEE` = **10%** and applies to
   **pair-flagged transfers only** (buys/sells) — plain transfers, including
   bridge lock/unlock, are untaxed unless the owner flags bridge addresses as
   pairs (then at most 10%). The owner can also retune `maxWalletAmount`
   (floor 0.1%) and the exclusion list. This risk applies to every NOXA holder
   and DEX user equally; a custody bridge concentrates it and must say so.
2. **Federated custody.** Unchanged from the README trust model: the peg rests
   on the authority Safe + hot keys + monitoring. The cap redesign does not
   change the trust model; it changes only custody topology.
3. **Cap changes.** The owner is live, so the cap value is owner-settable
   (floor 0.1% of supply). wNOXA v3 mirrors via `setMaxWalletAmount` (our
   owner tracks theirs); the fleet design tolerates a raised cap (boxes just
   stop spawning as often) and a lowered one (fill threshold is config).

## 6. Listing Q&A (answers for third parties vetting the bridge)

- **Who holds the mint key?** wNOXA mint is a revocable `isMinter` role held
  by the hot relayer key, granted/revoked by a cold owner Safe; supply is
  hard-capped at source supply; `pause()` is the circuit breaker; lockbox
  releases are rate-limited hot / uncapped cold-Safe. (README trust model.)
- **How does the bridge handle the 25K wallet cap?** Verified on-chain (§3).
  The wrapped token (`WrappedNoxaV3`) **replicates the cap** — no non-excluded
  wallet can hold >25K wNOXA, with exclusions only for bridge infra, exactly
  as NOXA excludes its own pool. Custody is still a single lockbox, so total
  bridged supply is capped ~25K until the sharded-custody fleet (§4.1/§4.2)
  ships; we do not claim a workaround, we replicate the cap.
- **What if a bridge mint would push a wallet over the cap?** It escrows in
  the token contract as a claimable balance (nonce settled, peg unchanged);
  the recipient claims once they have headroom. Nothing wedges.
- **How do you buy wNOXA without an LP pool?** You don't buy it — you bridge
  it. Lock-and-mint is 1:1 and needs no pool, no pricing, no counterparty
  liquidity. Buying wNOXA directly on Robinhood Chain is a separate optional
  layer that requires the (not-yet-seeded) wNOXA/WETH pool priced off NOXA's
  live DBK pool (§3); nothing about the peg depends on it.
