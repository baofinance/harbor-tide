#!/usr/bin/env bash
set -euo pipefail

# NON-deterministic ("unsalted") multichain deploy — wraps script/DeployUnsalted.s.sol.
# Deploys the token impl + ERC1967 proxy directly (no BaoFactory/CREATE3), so the proxy address is
# PER-CHAIN and is NOT the canonical cross-chain address. Intended as a TEST deploy (e.g. to start
# building the frontend) before you have BaoFactory operator rights for the real salted deploy.
#
# State/aux files are written to `-unsalted` variants so they never collide with the real salted deploy:
#   deployments/state-<chainId>-unsalted.json
#   deployments/aux-<chainId>-unsalted.json
#
# Multichain: pass --network all (or a comma list) to deploy every chain in one run.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}
ALL_NETWORKS="mainnet arbitrum base megaeth robinhood"

# Waits / retries (override via env).
TIMEOUT="${DEPLOY_TIMEOUT:-900}"
VERIFY_RETRIES="${VERIFY_RETRIES:-12}"
VERIFY_DELAY="${VERIFY_DELAY:-20}"

usage() {
  cat <<'EOF'
Usage:
  script/deploy-unsalted.sh --network <name|all|csv> [--account <keystore>] [--sender <addr>] [--verify] [--resume]

Options:
  --network <v>      Required. rpc_endpoints key, a comma list, or "all"
                     (mainnet,arbitrum,base,megaeth,robinhood).
  --account <name>   Foundry keystore account (default: $DEPLOYER_ACCOUNT or "deployer"). Or set PRIVATE_KEY.
  --sender <addr>    Deployer EOA (default: derived from the keystore account).
  --verify           Verify during deploy (default: off; prefer script/verify.sh --unsalted after).
  --resume           Pass --resume to forge.
  -h, --help         Show help.
EOF
}

NETWORK=""
ACCOUNT="${DEPLOYER_ACCOUNT:-deployer}"
SENDER=""
VERIFY=false
RESUME=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --account) ACCOUNT=${2:-}; shift 2 ;;
    --sender) SENDER=${2:-}; shift 2 ;;
    --verify) VERIFY=true; shift ;;
    --resume) RESUME=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f foundry.toml ]] || { echo "❌ Run from the repo root" >&2; exit 1; }
[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }

if [[ "$NETWORK" == "all" ]]; then
  read -r -a NETWORKS <<<"$ALL_NETWORKS"
else
  IFS=',' read -r -a NETWORKS <<<"$NETWORK"
fi

SIGNER=()
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  SIGNER=(--private-key "$PRIVATE_KEY")
  [[ -n "$SENDER" ]] || SENDER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
else
  if [[ -z "${DEPLOYER_ACCOUNT_PASSWORD:-}" ]]; then
    read -r -s -p "Keystore password for \"$ACCOUNT\" (hidden): " DEPLOYER_ACCOUNT_PASSWORD
    echo ""
    export DEPLOYER_ACCOUNT_PASSWORD
  fi
  SIGNER=(--account "$ACCOUNT" --password "$DEPLOYER_ACCOUNT_PASSWORD")
  [[ -n "$SENDER" ]] || SENDER=$("$CAST" wallet address "${SIGNER[@]}")
fi

run_one() {
  local network=$1 rpc_url chain_id
  rpc_url=$(resolve_rpc_url "$network")
  chain_id=$("$CAST" chain-id --rpc-url "$rpc_url")

  # Per-chain, per-run: keep the unsalted records separate from the canonical salted ones.
  export DEPLOY_STATE_FILE_READ="deployments/state-${chain_id}-unsalted.json"
  export DEPLOY_STATE_FILE_WRITE="deployments/state-${chain_id}-unsalted.json"
  export DEPLOY_AUX_SUFFIX="-unsalted"

  echo ""
  echo "=== Harbor Tide deploy (UNSALTED / no factory) — $network (chainId $chain_id) ==="
  echo "  sender: $SENDER   ⚠️ per-chain address (NOT canonical CREATE3). Test/fallback only."
  "$FORGE" build script/ccip/CCIPArtifacts.sol >/dev/null
  local cmd=("$FORGE" script script/DeployUnsalted.s.sol:DeployUnsalted
    --rpc-url "$rpc_url" --broadcast --slow --timeout "$TIMEOUT" --sender "$SENDER" "${SIGNER[@]}")
  [[ "$network" == "megaeth" ]] && cmd+=(--skip-simulation)
  [[ "$VERIFY" == true ]] && cmd+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
  [[ "$RESUME" == true ]] && cmd+=(--resume)
  "${cmd[@]}"
}

ok=(); failed=()
for net in "${NETWORKS[@]}"; do
  if run_one "$net"; then ok+=("$net"); else failed+=("$net"); echo "❌ unsalted deploy failed on $net (continuing)"; fi
done

echo ""
echo "=== Summary (unsalted) ==="
echo "  ok:     ${ok[*]:-none}"
echo "  failed: ${failed[*]:-none}"
echo "Addresses are per-chain (read deployments/aux-<chainId>-unsalted.json). Verify with:"
echo "  script/verify.sh --network <name> --unsalted"
[[ ${#failed[@]} -eq 0 ]]
