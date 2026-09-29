#!/usr/bin/env bash
set -euo pipefail

# Verify the deployed Harbor Tide contracts on Etherscan (V2), reading addresses + constructor data from
# the aux file written by the deploy scripts (deployments/aux-<chainId>[-unsalted].json):
#   - token implementation (HarborTideToken_v1)
#   - token proxy          (ERC1967Proxy — salted via BaoFactory CREATE3, or unsalted plain CREATE)
#   - Chainlink pool       (BurnMintTokenPool, solc 0.8.24)
#   - TimelockController   (home chain only)
# Failures don't abort the run; a summary is printed and a non-zero exit returned if anything failed.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}

MULTISIG="0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2"
TIMELOCK_MIN_DELAY=86400
SOLC="0.8.30"      # token / proxy / timelock
POOL_SOLC="0.8.24" # Chainlink BurnMintTokenPool (isolated compilation unit)

VERIFY_RETRIES="${VERIFY_RETRIES:-12}" # verification attempts (forge --retries) — rides out indexer lag
VERIFY_DELAY="${VERIFY_DELAY:-20}"     # seconds between attempts (forge --delay)

IMPL_PATH="src/token/HarborTideToken_v1.sol:HarborTideToken_v1"
OZ_PROXY_PATH="lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
POOL_PATH="lib/chainlink-brownie-contracts/contracts/src/v0.8/ccip/pools/BurnMintTokenPool.sol:BurnMintTokenPool"
TIMELOCK_PATH="lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController"

usage() {
  cat <<'EOF'
Usage:
  script/verify.sh --network <name> [--unsalted] [--aux <path>]

Options:
  --network <name>   Required. rpc_endpoints key in foundry.toml
                     (mainnet|arbitrum|base|megaeth|robinhood|local).
  --unsalted         Read the -unsalted aux file (for deploys made with deploy-unsalted.sh).
  --aux <path>       Explicit aux JSON path (overrides the default).
  -h, --help         Show help.
EOF
}

NETWORK=""
SUFFIX=""
AUX_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --unsalted) SUFFIX="-unsalted"; shift ;;
    --aux) AUX_OVERRIDE=${2:-}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required" >&2; exit 1; }
[[ -n "${ETHERSCAN_API_KEY:-}" ]] || { echo "❌ ETHERSCAN_API_KEY is not set" >&2; exit 1; }

RPC_URL=$(resolve_rpc_url "$NETWORK")
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL")

# forge verify-contract --chain accepts a numeric id for chains not in foundry's built-in name list.
VERIFY_CHAIN="$NETWORK"
[[ "$NETWORK" == "megaeth" ]] && VERIFY_CHAIN="4326"
[[ "$NETWORK" == "robinhood" ]] && VERIFY_CHAIN="4663"

# Per-chain CCIP addresses (mirror script/config/CCIPChains.sol) for the pool constructor args.
case "$CHAIN_ID" in
  1) ROUTER="0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D"; RMN="0x411dE17f12D1A34ecC7F45f49844626267c75e81" ;;
  42161) ROUTER="0x141fa059441E0ca23ce184B6A78bafD2A517DdE8"; RMN="0xC311a21e6fEf769344EB1515588B9d535662a145" ;;
  8453) ROUTER="0x881e3A65B4d4a04dD529061dd0071cf975F58bCD"; RMN="0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8" ;;
  4326) ROUTER="0xfa546248C54939AA6C48279CdC1EAf9A1125c411"; RMN="0xA27056438FfA1f286AB197488808692F0db93F8B" ;;
  4663) ROUTER="0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9"; RMN="0xe8464c353210Cc398A45dB2454FBc5BCd25fFf20" ;;
  *) echo "❌ Unsupported chainId $CHAIN_ID" >&2; exit 1 ;;
esac

AUX=${AUX_OVERRIDE:-"deployments/aux-${CHAIN_ID}${SUFFIX}.json"}
[[ -f "$AUX" ]] || { echo "❌ Aux file not found: $AUX" >&2; exit 1; }

TOKEN=$(jq -r '.token // empty' "$AUX")
TOKEN_IMPL=$(jq -r '.tokenImpl // empty' "$AUX")
TOKEN_INIT=$(jq -r '.tokenInitData // empty' "$AUX")
POOL=$(jq -r '.pool // empty' "$AUX")
TIMELOCK=$(jq -r '.timelock // empty' "$AUX")

echo "=== Verify Harbor Tide ==="
echo "  network:  $NETWORK (chainId $CHAIN_ID)"
echo "  aux:      $AUX"
echo "  token:    $TOKEN (ERC1967Proxy)"
[[ "$NETWORK" == "robinhood" ]] && echo "  verifier: Etherscan V2 (robin.etherscan.io / chainid=4663)"
echo ""

ok=0; fail=0; skip=0

verify_one() {
  local address=$1 contract_path=$2 ctor_args=$3 compiler=$4 label=$5

  if [[ -z "$address" || "$address" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "⏭  Skip $label: no address"; skip=$((skip + 1)); return
  fi
  local code
  code=$("$CAST" code "$address" --rpc-url "$RPC_URL" 2>/dev/null | head -n 1 || echo "0x")
  if [[ "$code" == "0x" ]]; then
    echo "⏭  Skip $label ($address): no code on-chain"; skip=$((skip + 1)); return
  fi

  echo "⏳ Verifying $label ($address) …"
  local -a cmd
  cmd=("$FORGE" verify-contract "$address" "$contract_path"
    --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY"
    --compiler-version "$compiler"
    --chain "$VERIFY_CHAIN"
    --watch --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
  # MegaETH / Robinhood: also pin Etherscan V2 URL with chainid (robin.etherscan.io / etc).
  # Without --chain, forge mislabels the target as "mainnet" and GUID polling fails.
  if [[ "$NETWORK" == "megaeth" ]]; then
    cmd+=(--verifier-url "https://api.etherscan.io/v2/api?chainid=4326")
  elif [[ "$NETWORK" == "robinhood" ]]; then
    cmd+=(--verifier-url "https://api.etherscan.io/v2/api?chainid=4663")
  fi
  [[ -n "$ctor_args" ]] && cmd+=(--constructor-args "$ctor_args")

  # Stream forge output live (retries can take minutes); keep a copy for the pass/fail check.
  local log
  log=$(mktemp)
  set +e
  "${cmd[@]}" 2>&1 | tee "$log"
  local forge_rc=${PIPESTATUS[0]}
  set -e
  if grep -qiE "successfully verified|already verified" "$log"; then
    echo "✅ $label ($address)"; ok=$((ok + 1))
  else
    echo "❌ $label ($address) (forge exit $forge_rc)"
    grep -iE "error|fail|reject|unable" "$log" | head -8 | sed 's/^/   /' || true
    fail=$((fail + 1))
  fi
  rm -f "$log"
}

# 1. Token implementation (no constructor args).
verify_one "$TOKEN_IMPL" "$IMPL_PATH" "" "$SOLC" "token implementation"

# 2. Token proxy — a standard ERC1967Proxy(impl, initData) for both salted and unsalted deploys.
PROXY_CTOR=$("$CAST" abi-encode "constructor(address,bytes)" "$TOKEN_IMPL" "$TOKEN_INIT")
verify_one "$TOKEN" "$OZ_PROXY_PATH" "$PROXY_CTOR" "$SOLC" "token proxy (ERC1967Proxy)"

# 3. Chainlink pool.
POOL_CTOR=$("$CAST" abi-encode "constructor(address,address[],address,address)" "$TOKEN" "[]" "$RMN" "$ROUTER")
verify_one "$POOL" "$POOL_PATH" "$POOL_CTOR" "$POOL_SOLC" "BurnMintTokenPool"

# 4. TimelockController (home chain only).
if [[ -n "$TIMELOCK" && "$TIMELOCK" != "0x0000000000000000000000000000000000000000" ]]; then
  TL_CTOR=$("$CAST" abi-encode "constructor(uint256,address[],address[],address)" \
    "$TIMELOCK_MIN_DELAY" "[$MULTISIG]" "[$MULTISIG]" "$MULTISIG")
  verify_one "$TIMELOCK" "$TIMELOCK_PATH" "$TL_CTOR" "$SOLC" "TimelockController"
fi

echo ""
echo "Done: ok=$ok fail=$fail skip=$skip"
[[ $fail -eq 0 ]]
