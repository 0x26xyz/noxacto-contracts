# noxacto-contracts

Solidity contracts for the **NOXA ⇄ wNOXA** federated lock-and-mint bridge
(DBK Chain ⇄ Robinhood Chain). Foundry project.

## Contracts

**Hardened (v2) — current:**
- `WrappedNoxaV2` — wNOXA on Robinhood Chain. Revocable `minter` role (separate from
  the cold owner), hard `ERC20Capped` supply cap, pause circuit-breaker, `Ownable2Step`
  (renounce disabled), a `mintMigration` path for the escrow migrator.
- `NoxaLockboxV2` — NOXA custody on DBK. Rate-limited hot `unlock` (per-tx cap +
  cooldown, pausable) separated from an uncapped `ownerUnlock`, fee-on-transfer-safe
  `lock` (balance-delta), per-burn-nonce replay guard.
- `WNoxaMigrator` — one-step 1:1 upgrade from an old wNOXA to a new one. **Escrows**
  the old token (never burns it, so the old lockbox's collateral keeps backing the
  new supply) and mints the new token; mints only against what it escrows.

**v1 (originals, still referenced during migration):** `WrappedNoxa`, `NoxaLockbox`,
`NoxaFeeBurner`, `NoxaLpLock`.

## Build & test

```bash
git submodule update --init --recursive   # or: forge install
forge build
forge test --no-match-path "*Fork*"        # unit + fuzz + invariant
forge test                                 # includes fork tests (needs an RPC)
```

## Deploy

Scripts live in `script/bridge/`. Copy `.env.example` → `.env` and fill it in.

```bash
# hardened v2 stack (see script/bridge/deploy-cutover.sh for the full orchestrated flow)
forge script script/bridge/DeployWrappedNoxaV2.s.sol:DeployWrappedNoxaV2 --rpc-url $RH_RPC_URL --broadcast
forge script script/bridge/DeployNoxaLockboxV2.s.sol:DeployNoxaLockboxV2 --rpc-url $DBK_RPC_URL --broadcast \
  --with-gas-price 3000000 --priority-gas-price 2000000
forge script script/bridge/DeployWNoxaMigrator.s.sol:DeployWNoxaMigrator --rpc-url $RH_RPC_URL --broadcast
```

`deploy-cutover.sh` runs all three, wires the minter roles, verifies, and writes the
addresses — see the header of that script for usage.

## Trust model

Federated / custodial bridge: the authority key is the trust anchor for mint (RH) and
unlock (DBK). The hardening bounds the blast radius of a compromised hot key (cap,
pause, rate-limited unlock, cold/hot role split) but does not make it trustless. Move
ownership to a multisig and monitor `NOXA.balanceOf(lockbox) >= wNOXA.totalSupply()`.

## License

[MIT](LICENSE).
