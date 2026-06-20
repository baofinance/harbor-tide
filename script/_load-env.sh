#!/usr/bin/env bash
# Sourced by the deploy/verify wrappers. Loads .env (and .env.local) and resolves an rpc alias to a URL.

# Load env files (exporting every var) if present.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
if [[ -f .env.local ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.local
  set +a
fi

# Map a foundry rpc_endpoints alias (mainnet|arbitrum|base|megaeth|local) to its RPC URL env var.
# Echoes the URL on stdout; non-zero exit if unset.
resolve_rpc_url() {
  local network=$1 url=""
  case "$network" in
    local) url=${LOCAL_URL:-} ;;
    mainnet) url=${MAINNET_RPC_URL:-} ;;
    arbitrum) url=${ARBITRUM_RPC_URL:-} ;;
    base) url=${BASE_RPC_URL:-} ;;
    megaeth) url=${MEGAETH_RPC_URL:-} ;;
    *)
      # Allow a raw URL to be passed through unchanged.
      if [[ "$network" == http*://* ]]; then url=$network; fi
      ;;
  esac
  if [[ -z "$url" ]]; then
    echo "❌ No RPC URL for network '$network' (set the matching *_RPC_URL in .env)" >&2
    return 1
  fi
  echo "$url"
}
