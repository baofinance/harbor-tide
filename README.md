# Harbor Tide

Upgradeable, hard-capped, Chainlink-CCIP omnichain ERC20, deployed deterministically through the
[BaoFactory](https://github.com/baofinance/bao-factory) (CREATE3) so the token shares **one address on
every chain**.

The token is modeled on the Sherlock-audited bao-base `MintableBurnableERC20_v1`, with three
additions required for this project: a 1 billion hard cap, a dedicated CCIP minter role, and the
Chainlink CCT admin/burn surface.

## Key properties

- **UUPS upgradeable** (`_authorizeUpgrade` gated by `onlyOwner`).
- **Roles inherited from bao-base** (`BaoOwnableRoles`):
  - `MINTER_ROLE` — governance minting, **home chain (Ethereum) only**. Held by an **external
    OpenZeppelin `TimelockController`** (default 24h min delay, Harbor multisig as proposer/executor),
    so every governance mint is time-delayed rather than instant. This replaces an in-token "minting
    window". Remote chains are **not** granted this role, so the 1bn stays a true *global* cap —
    remote supply can only arrive via CCIP (burn-bounded), never via a governance mint.
  - `CCIP_MINTER_ROLE` — held by the Chainlink token pool; lets CCIP re-materialize tokens that were
    burned on another chain.
  - `BURNER_ROLE` — held by the Chainlink token pool (and any governance burner).
- **1,000,000,000 hard cap** (`MAX_SUPPLY = 1_000_000_000e18`, 18 decimals), enforced on every mint.
  The full 1bn is minted to the Harbor multisig **only on Ethereum mainnet** (the home chain); remote
  chains start at 0 supply and receive tokens via CCIP.
- **CCIP (CCT) ready** — explicit Chainlink `IBurnMintERC20` surface (`mint`, `burn(uint256)`,
  `burn(address,uint256)`, `burnFrom`) plus `getCCIPAdmin()` (returns the owner / Harbor multisig).
  > Note: the token does **not** inherit Chainlink's `IBurnMintERC20` type, because that interface
  > extends a vendored OZ v4.8.3 `IERC20` which clashes with the OZ v5 `IERC20` from
  > `ERC20Upgradeable`. The exact selectors are implemented directly, so CCIP pools (which call by
  > selector) are fully compatible. See `src/token/interfaces/IHarborTideToken.sol`.
- **ERC20Permit** (no `ERC20Votes`).
- **`rescueERC20`** owner helper for unrelated tokens accidentally sent to the contract.

## Architecture

```
Harbor multisig ──owns──► HarborTideToken_v1 (UUPS proxy, same CREATE3 address per chain)
       │                        ▲  ▲
       │ proposer/executor      │  │ CCIP_MINTER_ROLE + BURNER_ROLE
       ▼                        │  │
TimelockController ──MINTER_ROLE─┘  └── Chainlink BurnMintTokenPool (immutable, per-chain)
                                              │
                                    TokenAdminRegistry / Router / RMN
```

CCIP pools are **immutable**; "upgrading" a pool means deploying a new one and migrating via
`setPool` in the `TokenAdminRegistry`. The token exposes `getCCIPAdmin()` for admin registration.

## Layout

```
src/token/HarborTideToken_v1.sol            # the token
src/token/interfaces/IHarborTideToken.sol   # cap / CCIP / rescue surface
script/src/HarborTideFactoryDeployer.sol    # bao-base FactoryDeployer subclass: state-driven CREATE3 deploy
script/src/TideDeployProxy.sol              # ERC1967 proxy that allows empty-init construction (via-stub)
script/config/CCIPChains.sol                # per-chain CCIP addresses + selectors
script/ccip/ICCIP.sol                       # version-agnostic CCIP call interfaces
script/ccip/CCIPArtifacts.sol               # forces compilation of the 0.8.24 Chainlink pool
script/Deploy.s.sol                         # token + timelock + pool + role wiring + handover
script/AcceptPoolOwnership.s.sol            # multisig accepts Ownable2Step pool ownership
script/Configure_CCIP.s.sol                 # registry registration + cross-chain lane wiring
deployments/state-<chainId>.json            # canonical proxy state (bao-base schema); idempotent re-runs
deployments/aux-<chainId>.json              # companion record for non-proxy contracts (timelock, pool)
test/                                        # unit, timelock, state-deploy, and (skip-guarded) CCIP fork tests
```

### Deployment state (same approach as the `harbor` repo)

`HarborTideFactoryDeployer` inherits bao-base's audited `FactoryDeployer`, so deploys are **state-driven**:
addresses are predicted up-front from the BaoFactory (CREATE3 — salt-only, identical on every chain),
each UUPS proxy is recorded in a `DeploymentState` JSON, and re-runs **skip** anything already recorded
instead of colliding. The token is a proxy and lives in the canonical `deployments/state-<chainId>.json`
(harbor's exact schema). The `TimelockController` and Chainlink pool are **not** proxies, so they're
recorded in a companion `deployments/aux-<chainId>.json` that the later steps read.

The proxy is deployed **via the stub pattern**: the BaoFactory CREATE3-deploys an empty (uninitialized)
proxy pointing at `UUPSProxyDeployStub`, then the deployer EOA immediately `upgradeToAndCall`s into the
real implementation. This keeps `BaoOwnable`'s temporary owner equal to the deployer (not the CREATE3
transient deployer). Because OpenZeppelin **v5.6.0** made `ERC1967Proxy` revert
(`ERC1967ProxyUninitialized()`) on empty init data, the deploy uses `TideDeployProxy` — an `ERC1967Proxy`
that overrides `_unsafeAllowUninitialized()` — for that first step. The proxy is never left
uninitialized on-chain (the upgrade+initialize is the very next call). This path is regression-tested
without a fork in `test/FactoryRepro.t.sol` and end-to-end against the live mainnet factory in
`test/DeployFork.t.sol`.

## Target chains

| Chain            | Chain ID | CCIP selector          |
| ---------------- | -------- | ---------------------- |
| Ethereum (home)  | 1        | 5009297550715157269    |
| Arbitrum One     | 42161    | 4949039107694359620    |
| Base             | 8453     | 15971525489660198786   |
| MegaETH          | 4326     | 6093540873831549674    |

CCIP router / RMN / registry addresses live in `script/config/CCIPChains.sol` (sourced from the
Chainlink CCIP mainnet directory — verify before any production deploy).

## Develop

```bash
forge build
forge test
forge fmt
```

This repo uses git submodules under `lib/`. After cloning:

```bash
git submodule update --init --recursive
```

## Deploy

> Confirm `HARBOR_MULTISIG` in `script/src/HarborTideFactoryDeployer.sol` and that the BaoFactory
> deployer key is authorized before broadcasting.

Deployment uses Foundry **keystore accounts** (`cast wallet`), not raw private keys. Import once with
`cast wallet import deployer --interactive`, then pass `--account deployer --sender <deployer-address>`
to each `forge script` call (shown below).

> **Prerequisite:** the BaoFactory (CREATE3) at `0xD696E56b3A054734d4C6DCBD32E11a278b0EC458` must
> already be deployed and functional on every target chain, with the deployer authorized as an
> operator. (Deployed/maintained separately, ahead of the token deploy.)

### 1. Per chain — token (CREATE3), timelock, pool, role wiring, ownership handover

This script sends several **dependent** transactions, so always use `--slow` (send the next tx only
after the previous one confirms). On a slow/congested mainnet also raise `--timeout`, and use
`--resume` to continue a run that stopped partway (CREATE3 makes re-runs land at the same addresses).

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url mainnet --broadcast --slow --timeout 600 \
  --account deployer --sender <deployer>
# add --resume to continue an interrupted run; add gas flags if base fee is spiking:
#   --with-gas-price <wei> --priority-gas-price <wei>

forge script script/Deploy.s.sol:Deploy --rpc-url arbitrum --broadcast --slow --account deployer --sender <deployer>
# ...base, megaeth
```

On mainnet the 1bn is minted to the multisig and the governance timelock (MINTER_ROLE) is deployed;
remote chains mint nothing and get **no** governance minter (CCIP-only supply, preserving the global
cap). Each run writes `deployments/state-<chainId>.json` (the token proxy) and `deployments/aux-<chainId>.json`
(timelock / pool — `timelock` is the zero address on remote chains) — keep these; later steps read them,
and they make re-runs idempotent. The Chainlink pool is `Ownable2Step`, so the multisig must accept
ownership next.

> Reliability (sleep between txs, receipt retries, timeouts) is handled by these `forge` flags, not by
> the script. `--slow` + `--timeout` + `--resume` is the robust combination for mainnet.

### 2. Per chain (as the multisig) — accept pool ownership

```bash
forge script script/AcceptPoolOwnership.s.sol:AcceptPoolOwnership \
  --rpc-url mainnet --broadcast --account multisig --sender 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2
# POOL is read from deployments/aux-<chainId>.json; override with POOL=0x... if needed.
```

### 3. Per chain (as the multisig) — register CCIP admin and wire lanes

Run this only **after** `Deploy` has run on all chains (so every `deployments/aux-<chainId>.json` exists).
Pool addresses are read automatically from those files; `REMOTE_CHAIN_IDS` defaults to the other three
target chains.

```bash
forge script script/Configure_CCIP.s.sol:Configure_CCIP \
  --rpc-url mainnet --broadcast --slow --timeout 600 \
  --account multisig --sender 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2
# Override if needed: POOL=0x... REMOTE_CHAIN_IDS=42161,8453 REMOTE_POOLS=0xArb...,0xBase...
```

(In practice the multisig steps are executed as a Safe batch; the scripts double as the reference for
the exact calls.) Rate limits are disabled by default in the lane config — set them per policy before
production.

### Verification

Etherscan API **V2** uses a single `ETHERSCAN_API_KEY` for all chains (including MegaETH via the V2
multichain endpoint). Add `--verify` to any deploy command, or verify after the fact with
`forge verify-contract --chain <id> ...`.

## Minting (governance, via the timelock)

Governance minting exists on the **home chain (Ethereum) only**. There, the token's `MINTER_ROLE` is
held solely by the `TimelockController`, so every governance mint is a two-step, time-delayed
operation run by the multisig: **schedule**, wait out the **24h** delay, then **execute**. (The operation stays executable indefinitely once ready — cancel it if you change your
mind. There is no automatic close window.)

Set up shell variables (addresses from your deployment):

```bash
TIMELOCK=0x<timelock>
TOKEN=0x<tideTokenProxy>           # same CREATE3 address on every chain
TO=0x<recipient>
AMOUNT=1000000000000000000000000   # 1,000,000 TIDE (18 decimals)
PREDECESSOR=0x0000000000000000000000000000000000000000000000000000000000000000
SALT=0x0000000000000000000000000000000000000000000000000000000000000001  # any unique value
DELAY=86400                         # 24h, must be >= timelock minDelay

# The inner call the timelock will make: HarborTideToken_v1.mint(TO, AMOUNT)
DATA=$(cast calldata "mint(address,uint256)" $TO $AMOUNT)
```

1. **Schedule** (multisig = proposer):

   ```bash
   cast send $TIMELOCK \
     "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
     $TOKEN 0 $DATA $PREDECESSOR $SALT $DELAY \
     --rpc-url mainnet --account multisig
   ```

2. **Check readiness** (optional). Compute the operation id, then poll its state:

   ```bash
   OPID=$(cast call $TIMELOCK \
     "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
     $TOKEN 0 $DATA $PREDECESSOR $SALT --rpc-url mainnet)

   cast call $TIMELOCK "isOperationReady(bytes32)(bool)" $OPID --rpc-url mainnet   # true after 24h
   cast call $TIMELOCK "getTimestamp(bytes32)(uint256)"   $OPID --rpc-url mainnet   # ready-at unix ts
   ```

3. **Execute** after the delay has elapsed (multisig = executor):

   ```bash
   cast send $TIMELOCK \
     "execute(address,uint256,bytes,bytes32,bytes32)" \
     $TOKEN 0 $DATA $PREDECESSOR $SALT \
     --rpc-url mainnet --account multisig
   ```

   `mint` enforces the 1bn hard cap, so a mint that would exceed `MAX_SUPPLY` reverts on execution.

To cancel a still-pending operation (multisig = canceller):

```bash
cast send $TIMELOCK "cancel(bytes32)" $OPID --rpc-url mainnet --account multisig
```

> In production these calls are typically assembled as a Safe transaction batch rather than `cast`,
> but the function signatures and arguments are identical.

## License

MIT
