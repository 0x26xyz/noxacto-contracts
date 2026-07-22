#!/usr/bin/env bash
#
# NOXA bridge — reconcile the migrator escrow into the v2 lockbox.
#
# Migrated v2 wNOXA is backed by OLD wNOXA escrowed in the WNoxaMigrator (in turn
# backed by the v1 lockbox). v2 redemptions pay out of the v2 lockbox only, so
# until this runs, every migrated holder's redemption reverts with
# "ERC20: transfer amount exceeds balance". This script moves the backing:
#
#   1. sweepEscrow(authority, amount)          migrator, RH   — cold key (owner)
#   2. burnForReturn(amount, v2Lockbox)        old wNOXA, RH  — hot key (authority)
#   3. unlock(amount, v2Lockbox, burnNonce)    v1 lockbox, DBK — hot key (owner)
#
# Both bridges stay fully collateralized at every step: the old-wNOXA burn (2)
# reduces v1 liabilities by exactly the NOXA that leaves the v1 lockbox (3), and
# the v2 lockbox gains the backing for the migrated v2 supply. Any unlock the
# relayer is retrying (e.g. burn nonce 0) settles automatically once (3) lands.
#
# Usage:
#   ./script/bridge/reconcile-migrator-escrow.sh [path-to-env]   # default .env.mainnet
#   YES=1 ...                # skip the confirmation prompt
#   AMOUNT=<wei> ...         # override (default: full migrator escrow balance);
#                            #   required when resuming after a sweep already ran
#   NONCE=<n> AMOUNT=<wei> ..# resume at step 3 only (sweep + burn already done;
#                            #   NONCE = the BurnedForReturn nonce from step 2)
#   V2_LOCKBOX_ADDRESS=0x... MIGRATOR_ADDRESS=0x...   # override v2 addresses
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# --- env -----------------------------------------------------------------------
ENV_FILE="${1:-$ROOT/.env.mainnet}"
[ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }
echo "using env: $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

command -v cast >/dev/null || { echo "cast not on PATH (source ~/.foundry/bin)" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq is required to parse the burn receipt" >&2; exit 1; }

# .env.mainnet carries the v1 addresses; v2 addresses are overridable here.
for v in PRIVATE_KEY DBK_DEPLOY_KEY RH_RPC_URL DBK_RPC_URL NOXA_ADDRESS NOXA_LOCKBOX_ADDRESS WRAPPED_NOXA_ADDRESS; do
  [ -n "${!v:-}" ] || { echo "missing required env var: $v (in $ENV_FILE)" >&2; exit 1; }
done
: "${V2_LOCKBOX_ADDRESS:=0x597E9c2839931683C3c9389eAb6Bf4a19801C8d3}"   # NoxaLockboxV2 (DBK)
: "${MIGRATOR_ADDRESS:=0x9085f12a9c55c1A2D4bA42F091E75A3b570Db488}"     # WNoxaMigrator (RH)
V1_LOCKBOX="$NOXA_LOCKBOX_ADDRESS"   # 0x7Bedd4…2E88
OLD_WNOXA="$WRAPPED_NOXA_ADDRESS"    # 0xC5b5cF…141B (v1 wNOXA — .env.mainnet predates v2)

DBK_GAS=(--gas-price 3000000 --priority-gas-price 2000000)   # DBK won't mine without these
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- keys + on-chain owner sanity checks ----------------------------------------
COLD="$(cast wallet address --private-key "$PRIVATE_KEY")"      # migrator owner
HOT="$(cast wallet address --private-key "$DBK_DEPLOY_KEY")"    # v1 lockbox owner / bridge authority

MIG_OWNER="$(cast call "$MIGRATOR_ADDRESS" 'owner()(address)' --rpc-url "$RH_RPC_URL")"
V1_OWNER="$(cast call "$V1_LOCKBOX" 'owner()(address)' --rpc-url "$DBK_RPC_URL")"
[ "$(lc "$MIG_OWNER")" = "$(lc "$COLD")" ] || { echo "PRIVATE_KEY ($COLD) is not the migrator owner ($MIG_OWNER)" >&2; exit 1; }
[ "$(lc "$V1_OWNER")"  = "$(lc "$HOT")"  ] || { echo "DBK_DEPLOY_KEY ($HOT) is not the v1 lockbox owner ($V1_OWNER)" >&2; exit 1; }

# --- amounts ---------------------------------------------------------------------
ESCROW="$(cast call "$OLD_WNOXA" 'balanceOf(address)(uint256)' "$MIGRATOR_ADDRESS" --rpc-url "$RH_RPC_URL" | awk '{print $1}')"
if [ -n "${NONCE:-}" ]; then
  [ -n "${AMOUNT:-}" ] || { echo "NONCE resume requires AMOUNT=<wei> (the amount burned in step 2)" >&2; exit 1; }
elif [ -z "${AMOUNT:-}" ]; then
  AMOUNT="$ESCROW"
  [ "$AMOUNT" != "0" ] || { echo "migrator escrow is 0 — nothing to sweep. If a sweep already ran, resume with AMOUNT=<wei> (and NONCE=<n> if the burn ran too)." >&2; exit 1; }
fi
V1_BAL="$(cast call "$NOXA_ADDRESS" 'balanceOf(address)(uint256)' "$V1_LOCKBOX" --rpc-url "$DBK_RPC_URL" | awk '{print $1}')"
python3 - "$V1_BAL" "$AMOUNT" <<'EOF' || { echo "v1 lockbox holds less NOXA than AMOUNT — aborting" >&2; exit 1; }
import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)
EOF

V2_BAL0="$(cast call "$NOXA_ADDRESS" 'balanceOf(address)(uint256)' "$V2_LOCKBOX_ADDRESS" --rpc-url "$DBK_RPC_URL" | awk '{print $1}')"

echo "== reconcile migrator escrow -> v2 lockbox =="
echo "   cold key (migrator owner)   = $COLD"
echo "   hot key  (authority)        = $HOT"
echo "   amount                      = $AMOUNT wei ($(cast from-wei "$AMOUNT") NOXA)"
echo "   migrator escrow (old wNOXA) = $ESCROW"
echo "   v1 lockbox NOXA             = $V1_BAL"
echo "   v2 lockbox NOXA (before)    = $V2_BAL0"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "proceed? [y/N] " ok
  [ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "aborted"; exit 1; }
fi

if [ -n "${NONCE:-}" ]; then
  echo "-- 1/3 + 2/3 skipped (resuming at step 3 with burn nonce $NONCE)"
else
  # --- 1. sweep escrow out of the migrator (RH, cold key) ------------------------
  if [ "$ESCROW" != "0" ]; then
    echo "-- 1/3 sweepEscrow($HOT, $AMOUNT) on migrator $MIGRATOR_ADDRESS"
    cast send "$MIGRATOR_ADDRESS" 'sweepEscrow(address,uint256)' "$HOT" "$AMOUNT" \
      --private-key "$PRIVATE_KEY" --rpc-url "$RH_RPC_URL" >/dev/null
  else
    echo "-- 1/3 skipped (escrow already 0; assuming a prior sweep — hot key must hold $AMOUNT old wNOXA)"
  fi

  # --- 2. burn old wNOXA with the v2 lockbox as DBK recipient (RH, hot key) ------
  echo "-- 2/3 burnForReturn($AMOUNT, $V2_LOCKBOX_ADDRESS) on old wNOXA $OLD_WNOXA"
  BURN_JSON="$(cast send "$OLD_WNOXA" 'burnForReturn(uint256,address)' "$AMOUNT" "$V2_LOCKBOX_ADDRESS" \
    --private-key "$DBK_DEPLOY_KEY" --rpc-url "$RH_RPC_URL" --json)"
  TOPIC="$(cast keccak 'BurnedForReturn(uint256,address,address,uint256)')"
  NONCE_HEX="$(echo "$BURN_JSON" | jq -r --arg a "$(lc "$OLD_WNOXA")" --arg t "$TOPIC" \
    '.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$t) | .topics[1]')"
  [ -n "$NONCE_HEX" ] && [ "$NONCE_HEX" != "null" ] || { echo "could not find BurnedForReturn in receipt: $BURN_JSON" >&2; exit 1; }
  NONCE="$(cast to-dec "$NONCE_HEX")"
  echo "   burn nonce = $NONCE (tx $(echo "$BURN_JSON" | jq -r .transactionHash))"
fi

# --- 3. release from v1 lockbox into the v2 lockbox (DBK, hot key) ---------------
PROCESSED="$(cast call "$V1_LOCKBOX" 'processedBurn(uint256)(bool)' "$NONCE" --rpc-url "$DBK_RPC_URL")"
[ "$PROCESSED" = "false" ] || { echo "v1 burn nonce $NONCE already processed — refusing to double-release" >&2; exit 1; }
echo "-- 3/3 unlock($AMOUNT, $V2_LOCKBOX_ADDRESS, $NONCE) on v1 lockbox $V1_LOCKBOX"
cast send "$V1_LOCKBOX" 'unlock(uint256,address,uint256)' "$AMOUNT" "$V2_LOCKBOX_ADDRESS" "$NONCE" \
  --private-key "$DBK_DEPLOY_KEY" --rpc-url "$DBK_RPC_URL" "${DBK_GAS[@]}" >/dev/null

# --- verify ----------------------------------------------------------------------
V2_BAL1="$(cast call "$NOXA_ADDRESS" 'balanceOf(address)(uint256)' "$V2_LOCKBOX_ADDRESS" --rpc-url "$DBK_RPC_URL" | awk '{print $1}')"
echo "v2 lockbox NOXA (after) = $V2_BAL1 ($(cast from-wei "$V2_BAL1") NOXA)"
python3 - "$V2_BAL0" "$V2_BAL1" "$AMOUNT" <<'EOF'
import sys
before, after, amt = (int(x) for x in sys.argv[1:4])
got = after - before
if got < amt:
    print(f"WARNING: v2 lockbox received {got} < {amt} — NOXA fee-on-transfer took a cut; "
          f"top up the difference or migrated supply stays fractionally under-backed.")
EOF

echo "-- waiting for the relayer to settle pending v2 redemptions (burn nonce 0)..."
for _ in $(seq 1 20); do
  DONE="$(cast call "$V2_LOCKBOX_ADDRESS" 'processedBurn(uint256)(bool)' 0 --rpc-url "$DBK_RPC_URL")"
  [ "$DONE" = "true" ] && { echo "   v2 burn nonce 0 settled — stuck redemption delivered."; break; }
  sleep 10
done
[ "${DONE:-false}" = "true" ] || echo "   not settled yet — check relayer logs (it retries every tick; this is safe to leave)."
echo "done."
