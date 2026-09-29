#!/usr/bin/env bash
set -euo pipefail

# Salted (CREATE3 via BaoFactory) deploy of the Harbor Tide stack — the canonical, address-stable path.
# Wraps script/Deploy.s.sol. Requires the deployer to be a BaoFactory operator on each target chain.
# For chains where you are not yet an operator, use script/deploy-unsalted.sh instead.
#
# Multichain: pass --network all (or a comma list) to deploy every chain in one run; the keystore
# password is prompted once and reused. Every chain lands at the SAME token address (CREATE3).

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}
ALL_NETWORKS="mainnet arbitrum base megaeth robinhood"

# Waits / retries (override via env). Mainnet can be slow, so give broadcasts and verification room.
TIMEOUT="${DEPLOY_TIMEOUT:-900}"        # seconds to wait for each tx to confirm (forge --timeout)
VERIFY_RETRIES="${VERIFY_RETRIES:-12}"  # verification attempts (forge --retries)
VERIFY_DELAY="${VERIFY_DELAY:-20}"      # seconds between verification attempts (forge --delay)

usage() {
  cat <<'EOF'
Usage:
  script/deploy.sh --network <name|all|csv> [--account <keystore>] [--sender <addr>] [--no-verify] [--resume]

Options:
  --network <v>      Required. rpc_endpoints key (mainnet|arbitrum|base|megaeth|robinhood|local),
                     a comma list (mainnet,arbitrum), or "all"
                     (mainnet,arbitrum,base,megaeth,robinhood).
  --account <name>   Foundry keystore account (default: $DEPLOYER_ACCOUNT or "deployer"). Or set PRIVATE_KEY.
  --sender <addr>    Deployer EOA (default: derived from the keystore account).
  --no-verify        Skip Etherscan verification (default: on; needs ETHERSCAN_API_KEY).
  --resume           Pass --resume to forge (continue an interrupted broadcast).
  -h, --help         Show help.
EOF
}

NETWORK=""
ACCOUNT="${DEPLOYER_ACCOUNT:-deployer}"
SENDER=""
VERIFY=true
RESUME=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --account) ACCOUNT=${2:-}; shift 2 ;;
    --sender) SENDER=${2:-}; shift 2 ;;
    --no-verify) VERIFY=false; shift ;;
    --resume) RESUME=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f foundry.toml ]] || { echo "❌ Run from the repo root" >&2; exit 1; }
[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }

# Expand the network selector into a list.
if [[ "$NETWORK" == "all" ]]; then
  read -r -a NETWORKS <<<"$ALL_NETWORKS"
else
  IFS=',' read -r -a NETWORKS <<<"$NETWORK"
fi

# Resolve the signer once (same account/key across every chain).
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

if [[ "$VERIFY" == true ]] && [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "⚠️  ETHERSCAN_API_KEY not set; continuing without --verify (run script/verify.sh later)."
  VERIFY=false
fi

run_one() {
  local network=$1 rpc_url
  rpc_url=$(resolve_rpc_url "$network")
  echo ""
  echo "=== Harbor Tide deploy (salted / CREATE3) — $network ==="
  echo "  sender: $SENDER   verify: $VERIFY"
  # BurnMintTokenPool is solc 0.8.24 (script/ccip/CCIPArtifacts.sol). `forge script` only compiles
  # the Deploy.s.sol graph (0.8.30), so the pool artifact must exist before vm.deployCode runs.
  "$FORGE" build script/ccip/CCIPArtifacts.sol >/dev/null
  local cmd=("$FORGE" script script/Deploy.s.sol:Deploy
    --rpc-url "$rpc_url" --broadcast --slow --timeout "$TIMEOUT" --sender "$SENDER" "${SIGNER[@]}")
  # MegaETH charges compute + storage intrinsic gas (min ~60k, not 21k). Foundry's local EVM
  # underestimates this unless --skip-simulation is set (see docs.megaeth.com/developer-docs).
  [[ "$network" == "megaeth" ]] && cmd+=(--skip-simulation)
  [[ "$VERIFY" == true ]] && cmd+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
  [[ "$RESUME" == true ]] && cmd+=(--resume)
  "${cmd[@]}"
}

ok=(); failed=()
for net in "${NETWORKS[@]}"; do
  if run_one "$net"; then ok+=("$net"); else failed+=("$net"); echo "❌ deploy failed on $net (continuing)"; fi
done

echo ""
echo "=== Summary ==="
echo "  ok:     ${ok[*]:-none}"
echo "  failed: ${failed[*]:-none}"
echo "Next: multisig accepts pool ownership, then run Configure_CCIP. Verify with script/verify.sh."
[[ ${#failed[@]} -eq 0 ]]
