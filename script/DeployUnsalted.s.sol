// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {HarborTideFactoryDeployer} from "@tide-script/src/HarborTideFactoryDeployer.sol";
import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";
import {CCIPChains} from "@tide-script/config/CCIPChains.sol";
import {ITokenPool} from "@tide-script/ccip/ICCIP.sol";

/// @notice NON-deterministic ("unsalted") deploy of the Harbor Tide stack: the token impl + ERC1967
///         proxy are deployed *directly* (plain CREATE, NOT BaoFactory/CREATE3), so the proxy address
///         is per-chain and is NOT the canonical cross-chain address.
/// @dev Use this only where the salted path can't run yet — e.g. a chain where the deployer is not a
///      BaoFactory operator (Arbitrum, for now) or a testnet. Run via `script/deploy-unsalted.sh`, which
///      points the state/aux files at `-unsalted` variants so they never collide with the real deploy.
///      The real, address-stable deploy is `script/Deploy.s.sol` (run via `script/deploy.sh`).
///
/// Ownership: `initialize` takes the deployer EOA explicitly as `HarborOwnable`'s temporary owner (same
/// as the salted `Deploy.s.sol` path, which passes the deployer to the direct CREATE3 deploy). Roles are
/// granted while the deployer still owns the token, then ownership is handed to the multisig (subject to
/// the same HarborOwnable 1h handover window).
///
/// Test split: on the home chain the 1bn is split 700m to the multisig and 300m to the deployer (so the
/// deployer can exercise the distribution script). This is test-only — production mints the full 1bn to
/// the multisig.
contract DeployUnsalted is HarborTideFactoryDeployer, Script {
    // Throwaway test token: distinct name/symbol so it can never be mistaken for the production TIDE.
    string internal constant TOKEN_NAME = "Harbor Tide TEST";
    string internal constant TOKEN_SYMBOL = "NOTIDE";
    uint256 internal constant TIMELOCK_MIN_DELAY = 24 hours;

    // Test-only home-chain split of the 1bn: 700m to the multisig, 300m to the deployer (so the
    // deployer can exercise the distribution script). Production Deploy.s.sol mints the full 1bn to
    // the multisig. The two must sum to MAX_SUPPLY.
    uint256 internal constant SPLIT_TO_MULTISIG = 700_000_000e18;
    uint256 internal constant SPLIT_TO_DEPLOYER = 300_000_000e18;

    function run() external {
        CCIPChains.Config memory ccip = CCIPChains.configFor(block.chainid);
        bool isHome = block.chainid == CCIPChains.ETHEREUM;

        DeploymentTypes.State memory state = _loadState();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers(); // the broadcasting EOA (--sender / --account)

        // 1. Token: impl + ERC1967 proxy deployed directly (no factory => per-chain address).
        // On the home chain we mint the full 1bn to the deployer, then split: 700m -> multisig,
        // 300m kept by the deployer. Remotes mint nothing.
        address token = _proxyAddr(state, "token");
        if (token != address(0)) {
            console.log("  token already in state -> %s (skipping)", token);
        } else {
            HarborTideToken_v1 impl = new HarborTideToken_v1();
            uint256 initialMint = isHome ? (SPLIT_TO_MULTISIG + SPLIT_TO_DEPLOYER) : 0;
            address mintTo = isHome ? deployer : owner(); // remote amount is 0, so recipient is moot
            bytes memory initData = abi.encodeCall(
                HarborTideToken_v1.initialize, (deployer, owner(), TOKEN_NAME, TOKEN_SYMBOL, mintTo, initialMint)
            );
            token = address(new ERC1967Proxy(address(impl), initData));

            _recordImplementation(state, "token", "HarborTideToken_v1.sol", "HarborTideToken_v1", address(impl));
            DeploymentState.recordProxy(
                state,
                DeploymentTypes.ProxyRecord({
                    id: "token",
                    proxy: token,
                    implementation: address(impl),
                    salt: "unsalted",
                    deploymentTime: uint64(block.timestamp)
                })
            );
            _registerForOwnershipTransfer(token, "token");
            _setTokenVerifyInfo(address(impl), initData);

            if (isHome) {
                // Deployer holds the full 1bn from init; send 700m to the multisig, keep 300m.
                HarborTideToken_v1(token).transfer(owner(), SPLIT_TO_MULTISIG);
                console.log("  token (UNSALTED TEST) %s", token);
                console.log("    split: %s NOTIDE -> multisig %s", SPLIT_TO_MULTISIG / 1e18, owner());
                console.log("    split: %s NOTIDE -> deployer %s", SPLIT_TO_DEPLOYER / 1e18, deployer);
            } else {
                console.log("  token (UNSALTED TEST) %s minted 0 NOTIDE (remote)", token);
            }
        }

        // 2 & 3. Timelock (home only) + Chainlink pool — non-proxy, recorded in the aux file.
        (address timelock, address pool) = _readAux(block.chainid);
        if (pool == address(0)) {
            if (isHome) {
                address[] memory multisigArr = new address[](1);
                multisigArr[0] = owner();
                timelock = address(new TimelockController(TIMELOCK_MIN_DELAY, multisigArr, multisigArr, owner()));
                HarborTideToken_v1(token).grantRoles(timelock, HarborTideToken_v1(token).MINTER_ROLE());
                console.log("    timelock %s holds MINTER_ROLE", timelock);
            } else {
                console.log("    remote chain: no governance MINTER_ROLE (CCIP-only supply)");
            }

            address[] memory allowlist = new address[](0);
            pool = vm.deployCode(
                "out/BurnMintTokenPool.sol/BurnMintTokenPool.json",
                abi.encode(token, allowlist, ccip.rmnProxy, ccip.router)
            );
            HarborTideToken_v1(token).grantRoles(
                pool, HarborTideToken_v1(token).CCIP_MINTER_ROLE() | HarborTideToken_v1(token).BURNER_ROLE()
            );
            ITokenPool(pool).transferOwnership(owner());
            console.log("    pool     %s", pool);
        } else {
            console.log("  timelock/pool already in aux -> pool %s (skipping)", pool);
        }

        // 4. Hand ownership to the multisig.
        _transferAllOwnerships();

        vm.stopBroadcast();

        require(HarborTideToken_v1(token).owner() == owner(), "DeployUnsalted: ownership not handed to multisig");

        _saveState(state);
        _writeAux(token, timelock, pool);

        console.log("Harbor Tide (UNSALTED) deployed on chainId %s", block.chainid);
        console.log("  token    %s  (per-chain address; NOT the canonical CREATE3 address)", token);
        console.log("  timelock %s", timelock);
        console.log("  pool     %s", pool);
        console.log("  state    -> %s", _stateFileWrite());
        console.log("  aux      -> %s", _auxPath(block.chainid));
    }

    /// @notice Find a recorded proxy address by id (for idempotent re-runs); 0 if absent.
    function _proxyAddr(DeploymentTypes.State memory state, string memory id) internal pure returns (address) {
        bytes32 want = keccak256(bytes(id));
        for (uint256 i = 0; i < state.proxies.length; i++) {
            if (keccak256(bytes(state.proxies[i].id)) == want) return state.proxies[i].proxy;
        }
        return address(0);
    }
}
