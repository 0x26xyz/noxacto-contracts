#!/usr/bin/env bash
#
# NOXA bridge hardened-redeploy cutover — Phase 1-3 (deploy, wire roles, verify).
# Sources your env file, deploys the three hardened contracts, auto-captures their
# addresses from the forge broadcast JSON, grants the hot relayer + migrator their
# minter roles, and verifies. Writes the new addresses to .env.bridge-v2.
#
# ROLE MODEL (cold/hot split):
#   OWNER   = the SIGNING key's address (cold admin: roles, pause, caps, ownerUnlock).
#             Transfer to a Safe later via 2-step. MUST be funded on BOTH chains.
#   RELAYER = the hot key (RH minter + DBK unlocker). Defaults to BRIDGE_AUTHORITY,
#             i.e. the key the relayer service already signs with.
#
# It does NOT repoint the live relayer or frontend — that's the next phase, after a
# test migration. Nothing here is irreversible for existing holders.
#
# Usage:
#   ./script/bridge/deploy-cutover.sh [path-to-env]      # default hunts for .env.mainnet
#   KEY_VAR=PRIVATE_KEY ./script/bridge/deploy-cutover.sh   # which env var signs (=owner)
#   RELAYER=0x... ./script/bridge/deploy-cutover.sh         # override the hot key
#   VERIFY=1 ./script/bridge/deploy-cutover.sh              # also run --verify
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# --- resolve env file (gitignored → lives in main repo root, not this worktree) --
if [ -n "${1:-}" ]; then
  ENV_FILE="$1"
else
  ENV_FILE=""
  for cand in "$ROOT/.env.mainnet" "$ROOT/../../../.env.mainnet"; do
    [ -f "$cand" ] && { ENV_FILE="$cand"; break; }
  done
fi
[ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || { echo "env file not found; pass a path as \$1" >&2; exit 1; }
echo "using env: $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

command -v forge >/dev/null || { echo "forge not on PATH (source ~/.foundry/bin)" >&2; exit 1; }
command -v cast  >/dev/null || { echo "cast not on PATH" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq is required to parse broadcast JSON" >&2; exit 1; }

# --- signing key = OWNER (funded on BOTH chains) ------------------------------
KEY_VAR="${KEY_VAR:-PRIVATE_KEY}"
PRIVATE_KEY="${!KEY_VAR:-}"
[ -n "$PRIVATE_KEY" ] || { echo "signing key env var '$KEY_VAR' is empty in $ENV_FILE" >&2; exit 1; }

for v in BRIDGE_AUTHORITY NOXA_ADDRESS WRAPPED_NOXA_ADDRESS RH_RPC_URL DBK_RPC_URL RH_CHAIN_ID DBK_CHAIN_ID; do
  [ -n "${!v:-}" ] || { echo "missing required env var: $v" >&2; exit 1; }
done

# --- role derivation ---------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
SIGNER="$(cast wallet address --private-key "$PRIVATE_KEY")"
OWNER="$SIGNER"                        # cold admin = signer
RELAYER="${RELAYER:-$BRIDGE_AUTHORITY}" # hot minter+unlocker
OLD_WNOXA_ADDR="$WRAPPED_NOXA_ADDRESS"
case "$RELAYER" in 0x????????????????????????????????????????) ;; *) echo "RELAYER not a 20-byte address: $RELAYER" >&2; exit 1;; esac
if [ "$(lc "$OWNER")" = "$(lc "$RELAYER")" ]; then
  echo "note: owner == relayer ($OWNER) — single-key mode, no cold/hot split yet."
fi

# --- tunable cutover params (Option 1: generous cap → relayer runs unchanged) --
: "${WNOXA_MAX_SUPPLY:=1000000000000000000000000}"  # 1e24 = real NOXA supply (verified on-chain)
: "${UNLOCK_CAP:=40000000000000000000}"             # 40e18 ≥ current total supply
: "${UNLOCK_COOLDOWN:=0}"                           # tighten later via setUnlockCooldown
DBK_GAS=(--with-gas-price 3000000 --priority-gas-price 2000000)
VERIFY_FLAG=(); [ "${VERIFY:-0}" = "1" ] && VERIFY_FLAG=(--verify)

broadcast_addr() { # $1=script basename $2=chainId $3=contractName
  jq -r --arg n "$3" '.transactions[] | select(.transactionType=="CREATE" and .contractName==$n) | .contractAddress' \
    "broadcast/$1/$2/run-latest.json" | head -1
}

echo "== NOXA bridge cutover (deploy + wire + verify) =="
echo "   signing with \$$KEY_VAR"
echo "   OWNER (cold admin)         = $OWNER"
echo "   RELAYER (minter+unlocker)  = $RELAYER"
echo "   cap=$UNLOCK_CAP cooldown=$UNLOCK_COOLDOWN maxSupply=$WNOXA_MAX_SUPPLY"
echo

# --- Step 1: WrappedNoxaV2 on Robinhood Chain --------------------------------
echo "== [1/5] Deploy WrappedNoxaV2 (RH $RH_CHAIN_ID) =="
if [ -n "${WNOXA_V2:-}" ]; then
  echo "   reusing preset WNOXA_V2=$WNOXA_V2 (skipping deploy)"
else
  BRIDGE_AUTHORITY="$OWNER" WNOXA_MAX_SUPPLY="$WNOXA_MAX_SUPPLY" PRIVATE_KEY="$PRIVATE_KEY" \
    forge script script/bridge/DeployWrappedNoxaV2.s.sol:DeployWrappedNoxaV2 \
    --rpc-url "$RH_RPC_URL" --broadcast ${VERIFY_FLAG[@]+"${VERIFY_FLAG[@]}"}
  WNOXA_V2="$(broadcast_addr DeployWrappedNoxaV2.s.sol "$RH_CHAIN_ID" WrappedNoxaV2)"
  [ -n "$WNOXA_V2" ] && [ "$WNOXA_V2" != null ] || { echo "could not read WrappedNoxaV2 address" >&2; exit 1; }
fi
echo "   WNOXA_V2=$WNOXA_V2"; echo

# --- Step 2: NoxaLockboxV2 on DBK (owner=OWNER, hot unlocker=RELAYER) ---------
echo "== [2/5] Deploy NoxaLockboxV2 (DBK $DBK_CHAIN_ID) =="
if [ -n "${LOCKBOX_V2:-}" ]; then
  echo "   reusing preset LOCKBOX_V2=$LOCKBOX_V2 (skipping deploy)"
else
  NOXA_ADDRESS="$NOXA_ADDRESS" BRIDGE_AUTHORITY="$OWNER" UNLOCKER="$RELAYER" \
  UNLOCK_CAP="$UNLOCK_CAP" UNLOCK_COOLDOWN="$UNLOCK_COOLDOWN" PRIVATE_KEY="$PRIVATE_KEY" \
    forge script script/bridge/DeployNoxaLockboxV2.s.sol:DeployNoxaLockboxV2 \
    --rpc-url "$DBK_RPC_URL" --broadcast "${DBK_GAS[@]}" ${VERIFY_FLAG[@]+"${VERIFY_FLAG[@]}"}
  LOCKBOX_V2="$(broadcast_addr DeployNoxaLockboxV2.s.sol "$DBK_CHAIN_ID" NoxaLockboxV2)"
  [ -n "$LOCKBOX_V2" ] && [ "$LOCKBOX_V2" != null ] || { echo "could not read NoxaLockboxV2 address" >&2; exit 1; }
fi
echo "   LOCKBOX_V2=$LOCKBOX_V2"; echo

# --- Step 3: WNoxaMigrator on Robinhood Chain --------------------------------
echo "== [3/5] Deploy WNoxaMigrator (RH $RH_CHAIN_ID) =="
if [ -n "${MIGRATOR:-}" ]; then
  echo "   reusing preset MIGRATOR=$MIGRATOR (skipping deploy)"
else
  OLD_WNOXA="$OLD_WNOXA_ADDR" NEW_WNOXA="$WNOXA_V2" MIGRATOR_OWNER="$OWNER" PRIVATE_KEY="$PRIVATE_KEY" \
    forge script script/bridge/DeployWNoxaMigrator.s.sol:DeployWNoxaMigrator \
    --rpc-url "$RH_RPC_URL" --broadcast ${VERIFY_FLAG[@]+"${VERIFY_FLAG[@]}"}
  MIGRATOR="$(broadcast_addr DeployWNoxaMigrator.s.sol "$RH_CHAIN_ID" WNoxaMigrator)"
  [ -n "$MIGRATOR" ] && [ "$MIGRATOR" != null ] || { echo "could not read WNoxaMigrator address" >&2; exit 1; }
fi
echo "   MIGRATOR=$MIGRATOR"; echo

# --- Step 4: grant minter roles (signed by OWNER) ----------------------------
echo "== [4/5] Wire roles: grant minter to relayer + migrator =="
cast send "$WNOXA_V2" "setMinter(address,bool)" "$RELAYER"  true --rpc-url "$RH_RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$WNOXA_V2" "setMinter(address,bool)" "$MIGRATOR" true --rpc-url "$RH_RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "   granted isMinter to $RELAYER (relayer) and $MIGRATOR (migrator)"; echo

# --- Step 5: verify ----------------------------------------------------------
echo "== [5/5] Verify =="
printf '   owner()          = %s\n' "$(cast call "$WNOXA_V2" 'owner()(address)' --rpc-url "$RH_RPC_URL")"
printf '   cap()            = %s\n' "$(cast call "$WNOXA_V2" 'cap()(uint256)' --rpc-url "$RH_RPC_URL")"
printf '   isMinter(relayer)= %s\n' "$(cast call "$WNOXA_V2" 'isMinter(address)(bool)' "$RELAYER" --rpc-url "$RH_RPC_URL")"
printf '   isMinter(migr)   = %s\n' "$(cast call "$WNOXA_V2" 'isMinter(address)(bool)' "$MIGRATOR" --rpc-url "$RH_RPC_URL")"
printf '   lockbox.owner()  = %s\n' "$(cast call "$LOCKBOX_V2" 'owner()(address)' --rpc-url "$DBK_RPC_URL")"
printf '   lockbox.unlocker = %s\n' "$(cast call "$LOCKBOX_V2" 'unlocker()(address)' --rpc-url "$DBK_RPC_URL")"
printf '   lockbox.cap()    = %s\n' "$(cast call "$LOCKBOX_V2" 'unlockCap()(uint256)' --rpc-url "$DBK_RPC_URL")"

OUT="$ROOT/.env.bridge-v2"
{
  echo "# NOXA bridge v2 — deployed $(date -u +%FT%TZ)"
  echo "OWNER=$OWNER"
  echo "RELAYER=$RELAYER"
  echo "WNOXA_V2=$WNOXA_V2"
  echo "LOCKBOX_V2=$LOCKBOX_V2"
  echo "MIGRATOR=$MIGRATOR"
  echo "OLD_WNOXA=$OLD_WNOXA_ADDR"
} > "$OUT"
echo
echo "== DONE (deploy+wire+verify). Addresses written to $OUT =="
echo "   NEXT: grab the deploy block numbers, run the test migration, THEN repoint"
echo "   the relayer + frontend. Do NOT cut over yet."
