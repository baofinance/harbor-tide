// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {HarborTideFactoryDeployer} from "@tide-script/src/HarborTideFactoryDeployer.sol";
import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";
import {CCIPChains} from "@tide-script/config/CCIPChains.sol";
import {ITokenPool} from "@tide-script/ccip/ICCIP.sol";

/// @notice State-driven deploy of the Harbor Tide stack on one chain.
/// @dev Mirrors the harbor repo's flow: predict-then-deploy with a persisted state file.
///        - The token (UUPS proxy) lives in the canonical `DeploymentState` (idempotent: a re-run
///          skips it instead of colliding on CREATE3) and is recorded to `deployments/state-<id>.json`.
///        - The `TimelockController` (home chain only) and Chainlink `BurnMintTokenPool` are non-proxy
///          contracts, recorded to `deployments/aux-<id>.json` (which also guards their re-deploy).
///      Home chain (Ethereum) mints the full 1bn to the multisig; remote chains mint nothing (supply
///      arrives via CCIP). CCIP TokenAdminRegistry wiring is a multisig action — see `Configure_CCIP`.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url <network> --broadcast --slow --timeout 600 \
///     --account deployer --sender <deployer>
contract Deploy is HarborTideFactoryDeployer, Script {
    string internal constant TOKEN_NAME = "Harbor Tide";
    string internal constant TOKEN_SYMBOL = "TIDE";

    /// @notice Governance timelock minimum delay (the "no surprise mints" guardrail).
    uint256 internal constant TIMELOCK_MIN_DELAY = 24 hours;

    function run() external {
        CCIPChains.Config memory ccip = CCIPChains.configFor(block.chainid);
        bool isHome = block.chainid == CCIPChains.ETHEREUM;

        // Predict-then-deploy: load (or initialise) this chain's state before touching the chain.
        DeploymentTypes.State memory state = _loadState();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers(); // the broadcasting EOA (--sender / --account)

        // 1. Token (UUPS proxy) — canonical state, idempotent across re-runs.
        // Deployed directly via BaoFactory CREATE3 (`_deployProxyAndRecord`): `HarborOwnableRoles` takes
        // the deployer explicitly, so the proxy needs no via-stub. The deployer EOA is the temporary
        // owner that grants roles and completes the handover; the multisig is the final owner.
        address token;
        if (DeploymentState.hasProxy(state, "token")) {
            token = _predictAddress("token");
            console.log("  token already in state -> %s (skipping)", token);
        } else {
            HarborTideToken_v1 impl = new HarborTideToken_v1();
            uint256 initialMint = isHome ? impl.MAX_SUPPLY() : 0;
            bytes memory initData = abi.encodeCall(
                HarborTideToken_v1.initialize, (deployer, owner(), TOKEN_NAME, TOKEN_SYMBOL, owner(), initialMint)
            );
            _recordImplementation(state, "token", "HarborTideToken_v1.sol", "HarborTideToken_v1", address(impl));
            token = _deployProxyAndRecord(state, "token", address(impl), initData);
            _setTokenVerifyInfo(address(impl), initData);
            console.log("  token minted initial supply: %s TIDE", initialMint / 1e18);
        }

        // 2 & 3. Timelock (home only) + Chainlink pool — non-proxy, recorded in the aux file (idempotent).
        (address timelock, address pool) = _readAux(block.chainid);
        if (pool == address(0)) {
            // Governance minting exists ONLY on the home chain, so the 1bn stays a true *global* cap:
            // remote chains receive supply solely via CCIP (burn-bounded), never via a governance mint.
            if (isHome) {
                address[] memory multisigArr = new address[](1);
                multisigArr[0] = owner();
                timelock =
                    address(new TimelockController(TIMELOCK_MIN_DELAY, multisigArr, multisigArr, owner()));
                HarborTideToken_v1(token).grantRoles(timelock, HarborTideToken_v1(token).MINTER_ROLE());
                console.log("    timelock %s (minDelay %s) holds MINTER_ROLE", timelock, TIMELOCK_MIN_DELAY);
            } else {
                console.log("    remote chain: no governance MINTER_ROLE (CCIP-only supply)");
            }

            // Chainlink BurnMintTokenPool (immutable). Deployed via artifact to avoid the 0.8.24 pragma clash.
            address[] memory allowlist = new address[](0);
            pool = vm.deployCode(
                "out/BurnMintTokenPool.sol/BurnMintTokenPool.json",
                abi.encode(token, allowlist, ccip.rmnProxy, ccip.router)
            );
            HarborTideToken_v1(token).grantRoles(
                pool, HarborTideToken_v1(token).CCIP_MINTER_ROLE() | HarborTideToken_v1(token).BURNER_ROLE()
            );
            // Pool is Ownable2Step -> multisig must accept (see AcceptPoolOwnership.s.sol).
            ITokenPool(pool).transferOwnership(owner());
            console.log("    pool     %s", pool);
        } else {
            console.log("  timelock/pool already in aux -> pool %s (skipping)", pool);
        }

        // 4. Hand token (and any other registered proxy) ownership to the multisig.
        _transferAllOwnerships();

        vm.stopBroadcast();

        // Fail loud if the handover did not complete (e.g. an interrupted run that missed HarborOwnable's
        // 1h window): the token must be owned by the multisig before we consider the deploy done.
        require(HarborTideToken_v1(token).owner() == owner(), "Deploy: ownership not handed to multisig");

        // Persist: canonical proxy state + companion record for the non-proxy contracts.
        _saveState(state);
        _writeAux(token, timelock, pool);

        console.log("Harbor Tide deployed on chainId %s", block.chainid);
        console.log("  token    %s", token);
        console.log("  timelock %s", timelock);
        console.log("  pool     %s", pool);
        console.log("  state    -> %s", _stateFileWrite());
        console.log("  aux      -> %s", _auxPath(block.chainid));
        console.log("  NEXT (multisig): accept pool ownership, then run Configure_CCIP.s.sol");
    }
}
