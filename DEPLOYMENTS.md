# NOXA bridge — live mainnet deployments

Addresses only. No secrets. Committed deliberately so this survives losing a
laptop: the machine-readable copy lives in `merrymen_wtf/deploy/noxa-corridors.addresses.env`,
which is gitignored. Keep the two in step.

Last updated 2026-07-23.

## Shape

Two independent corridors. Real NOXA is custodied on DBK Chain; each corridor
has its **own** lockbox manager on DBK and its **own** wNOXA. That is
deliberate: `totalCollateral() == wNOXA.totalSupply()` is then a per-corridor
invariant the relayer's drift breaker can check independently, and one corridor
can never spend another's backing.

## Source chain — DBK (20240603)

| What | Address |
| --- | --- |
| NOXA | `0x6778980c66bcd9A8F74D73BD1b608483c40E8DdE` |

25,000 max-wallet cap, enforced on the recipient. Exclusions are hardcoded in
the verified source: owner / token / **DEAD** / `_isNoxaPair` / an owner-set
list. DEAD being hardcoded is what makes the burn fee safe: the skim can never
cap-revert and the exclusion cannot be revoked.

## Corridor 1 — DBK <-> Robinhood (4663)

| What | Address | Notes |
| --- | --- | --- |
| LockboxManager (DBK) | `0x5B4e0dff9C555b77312673e84Dd2753E59F0c978` | block 33664339, `bridgeFeeBps` 100 |
| shard 0 | `0x671155AE0046783eA4F181D078fD3F58EC76d4b4` | |
| wNOXA | `0x4eA5eEfF68A6F0848A9d5ab3a21F4Fe1b20ECcDc` | block 16527974, cap 1e24, maxWallet 25000e18 |
| WNoxaMigrator | `0x8053826aD49b5ae7d53364eeb5FD81CdEF0f95a4` | v2 -> v3 stragglers |
| LP pool wNOXA/WETH 1% | `0xE3f24D39bEEf85fd1798e1A84E02d94a93644c21` | |
| NoxaLpLock | `0x221B1795f1dba3b6991E0EB994E373e780bC93F9` | position 321540, locked |
| NoxaFeeBurner | `0x2CcEDda0D36bc4BD7f9231cD627B348509Cdac81` | |

`lockNonce` starts at 3: nonces 0-2 were burned by dust locks during the
fee-cutover migration, because wNOXA's `processedLock` had already consumed
them under the previous manager (see the landmine note below).

## Corridor 2 — DBK <-> Stable (988)

| What | Address | Notes |
| --- | --- | --- |
| LockboxManager (DBK) | `0x823A748eFBD8b68ea99d3bb6b55149FBDE0ffC91` | block 33668716, `bridgeFeeBps` 100 |
| shard 0 | `0x651F07988F199DbEdF71395c81c167D29e84977F` | |
| wNOXA | `0x9Fe50e7f1445aB592D768810Ad19d50f4cC7DE51` | block 32800516, same params as RH |
| LP pool wNOXA/USDT0 1% | `0xe0A039EF3a07c77B1CF8aC6D325CF7164ceE5e53` | cap-excluded |
| NoxaLpLock | `0xcbcf7bbe6ea8e4dCC99fCC9A1890f74A50752D6B` | position 330, locked |
| NoxaFeeBurner | `0xCd7856bB75784C953957260aC0F54486aC87C0c4` | |

Stable chain infrastructure: USDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`
(native gas **and** a 6-decimal ERC-20), V3 factory
`0x88F0a512eF09175D456bc9547f914f48C013E4aA`, position manager
`0x3BdC3437405f7D801b6036532713fc1F179136a6`, SwapRouter02
`0x32eaf9B5d5F2CD7361c5012890C943D7de84C22a`, quoter
`0xb070179E7032CdA868b53e6C1742F80c9e940d1A`.

## Retired — do not send funds

Drained to zero. Locking into any of these strands the deposit.

- pre-fee manager `0x950F5F62776b1eB988921C69376e4AD34b46BfFD` (also paused)
- managers `0xbB647251aC01F9Afe4a1b2fe3364149f211030Ad`, `0xA3975D98A22719E0dd870F197F221f0aC7D0E64A`
- lockboxes `0x82939fAD55F2Fffd34636823B33f3b7B90949D5D`, `0x597E9c2839931683C3c9389eAb6Bf4a19801C8d3`, `0x7Bedd4A877953BB4b6513e6287e98D01C98a2E88`
- wNOXA `0x4044aa6e7d77ccD82D02049755Ec679f3A8c760F`, `0xB31D1fe329870bef3e3A6761ba0ed469BdF806C5`, `0xC5b5cFE2f53351235BF60EA8b6E77fd77BEd141B`
- orphaned `NoxaLpLock` `0x74bDeE61B5680744D0A54Fe01C710eA207f319C0` on Stable, from a
  partial seed run; empty, holds no position

## Roles

Both corridors share two keys, held in `merrymen_wtf/.env.mainnet`:

- **Cold `0xd2b12D73eE8690F7F59e63D2Fd15fB49a8417099`** (`PRIVATE_KEY`) — owner of
  both managers, both wNOXAs and both fee burners. Signs `pause`,
  `ownerDrainShard`, `setBridgeFeeBps`, `setMinter`, `setCapExcluded`.
- **Hot `0xfB1Af79c5163cA0062F733A5184c831a8444E796`** (`DBK_DEPLOY_KEY`) — relayer
  unlocker on both managers, minter on both wNOXAs, fee-burner keeper, LpLock
  seeder.

Ownership is still cold EOAs, **not a Safe**. That is the top residual risk on
this stack.

## Traps worth knowing

- **`BRIDGE_AUTHORITY` in `.env.mainnet` is the HOT key.** Any deploy script
  taking an owner (`BRIDGE_AUTHORITY_COLD`, `BURN_KEEPER_OWNER`) must be passed
  the cold key explicitly or the contract deploys hot-owned.
- **`processedLock` is one namespace per wNOXA, across lockbox generations, with
  no owner clear.** Pointing a fresh manager at an existing wNOXA means its
  first locks reuse already-consumed nonces and the mints revert
  `AlreadyProcessed`, stranding deposits. Either burn the overlap with dust
  locks or deploy a fresh wNOXA (which is why the Stable corridor needed
  neither).
- **Repointing `LOCKBOX_ADDRESS` resets the relayer's RH cursor.** The cursor
  file is namespaced by lockbox+wNOXA, so a new manager rescans burn history
  against an empty `processedBurn` and would re-pay settled burns. Set
  `RH_START_BLOCK` to the current tip at cutover.
- **Stable is Cosmos-EVM: use `forge script --slow`.** It rejects transactions
  whose nonce runs ahead of the account nonce, so a normal batched broadcast
  dies partway through.
- **Stable's public RPC `rpc.stable.xyz` returns empty or erroring `eth_getLogs`.**
  Fine for `eth_call`, unusable for log scans. Use the private Alchemy endpoint
  (`STABLE_RPC_URL` in `.env.stable-mainnet.local`) for anything reading events.
