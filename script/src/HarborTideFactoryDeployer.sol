// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {FactoryDeployer, WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";

/// @title HarborTideFactoryDeployer
/// @notice Harbor-specific base for the Harbor Tide deploy scripts.
/// @dev Inherits the audited bao-base `FactoryDeployer`, so Harbor Tide uses the *same* state-driven
///      deployment flow as the `harbor` repo:
///        - addresses are predicted up-front from the BaoFactory (CREATE3, salt-only — identical on
///          every chain);
///        - each UUPS proxy is recorded in a `DeploymentTypes.State` and persisted to a JSON state
///          file (same schema/format as harbor), making the proxy deploy *idempotent* (re-runs skip
///          anything already in state instead of colliding on CREATE3);
///        - ownership is collected via the registry pattern and handed to the multisig at the end.
///
/// @dev Harbor's `DeploymentState` only models UUPS proxies + their implementations (everything harbor
///      deploys is a proxy). Harbor Tide's *token* is a proxy and lives in that canonical state. The
///      `TimelockController` (plain OZ contract) and the Chainlink `BurnMintTokenPool` (third-party,
///      non-proxy, non-deterministic address) do not fit that schema, so they are recorded in a small
///      companion `deployments/aux-<chainId>.json` that later scripts read (and that also makes their
///      deploy step idempotent).
abstract contract HarborTideFactoryDeployer is FactoryDeployer {
    /// @dev Foundry VM (private so it never clashes with `Script.vm` in the concrete script).
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Harbor multisig — final owner / treasury / CCIP admin (same address on every chain).
    address internal constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Salt namespace for all Harbor Tide deployments (permanently fixes the cross-chain address).
    string internal constant SALT_PREFIX = "harbor_tide_v1";

    // ========== FactoryDeployer configuration ==========

    /// @inheritdoc FactoryDeployer
    function owner() public pure override returns (address) {
        return HARBOR_MULTISIG;
    }

    /// @inheritdoc FactoryDeployer
    function treasury() public pure override returns (address) {
        return HARBOR_MULTISIG;
    }

    /// @notice Fixed salt prefix (overrides the settable default so scripts need no `_setSaltPrefix`).
    function saltPrefix() public pure override returns (string memory) {
        return SALT_PREFIX;
    }

    /// @notice Well-known addresses for readable logs/labels.
    function getWellKnownAddresses() public view virtual override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](2);
        addrs[0] = WellKnownAddress({addr: HARBOR_MULTISIG, label: "harbor_multisig"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
    }

    // ========== State-file plumbing ==========
    // Defaults to `deployments/state-<chainId>.json` so the scripts work standalone, but still honours
    // the DEPLOY_STATE_FILE_* env vars that harbor's `run-script` harness sets.

    function _defaultStatePath() internal view returns (string memory) {
        return string.concat("deployments/state-", _vm.toString(block.chainid), ".json");
    }

    function _stateFileRead() internal view override returns (string memory) {
        return _vm.envOr("DEPLOY_STATE_FILE_READ", _defaultStatePath());
    }

    function _stateFileWrite() internal view override returns (string memory) {
        return _vm.envOr("DEPLOY_STATE_FILE_WRITE", _defaultStatePath());
    }

    /// @notice Persist state as JSON (harbor's exact schema) without requiring ffi / DEPLOY_STATE_DIR.
    /// @dev Overrides the bao-base atomic-mv save so the scripts are self-contained.
    function _saveState(DeploymentTypes.State memory stateData) internal override {
        if (!_shouldPersistState()) return;
        _vm.createDir("deployments", true);
        _vm.writeFile(_stateFileWrite(), JsonSerializer.renderState(stateData));
    }

    /// @notice Load (or initialise) the deployment state for this chain.
    function _loadState() internal view returns (DeploymentTypes.State memory stateData) {
        stateData = DeploymentState.load(_stateFileRead());
        stateData.network = _networkName();
        stateData.saltPrefix = SALT_PREFIX;
        stateData.baoFactory = baoFactory();
    }

    function _networkName() internal view returns (string memory) {
        return string.concat("chain-", _vm.toString(block.chainid));
    }

    // ========== Aux record (non-proxy contracts: timelock + pool) ==========

    /// @dev Honours `DEPLOY_AUX_SUFFIX` so the unsalted (no-factory) deploy can write to a separate
    ///      `deployments/aux-<chainId>-unsalted.json` without clobbering the canonical salted record.
    function _auxPath(uint256 chainId) internal view returns (string memory) {
        return string.concat(
            "deployments/aux-", _vm.toString(chainId), _vm.envOr("DEPLOY_AUX_SUFFIX", string("")), ".json"
        );
    }

    // ========== Verification metadata (consumed by script/verify.sh) ==========
    // Captured during the token deploy so verify.sh can reconstruct the proxy's constructor args from the
    // aux file. Both the salted (BaoFactory CREATE3, direct) and unsalted (plain CREATE) paths deploy a
    // standard OZ `ERC1967Proxy(impl, initData)`, so the only metadata needed is the impl + init data.

    address internal _verifyTokenImpl;
    bytes internal _verifyTokenInitData;

    function _setTokenVerifyInfo(address impl, bytes memory initData) internal {
        _verifyTokenImpl = impl;
        _verifyTokenInitData = initData;
    }

    /// @notice Record the non-proxy contracts (+ token verify metadata) so later scripts (and other
    ///         chains) can read them, and so `verify.sh` can rebuild each contract's constructor args.
    function _writeAux(address token, address timelock, address pool) internal {
        _vm.createDir("deployments", true);
        string memory obj = "harbor-tide-aux";
        _vm.serializeUint(obj, "chainId", block.chainid);
        _vm.serializeAddress(obj, "token", token);
        _vm.serializeAddress(obj, "timelock", timelock);
        _vm.serializeAddress(obj, "pool", pool);
        _vm.serializeAddress(obj, "tokenImpl", _verifyTokenImpl);
        string memory json = _vm.serializeBytes(obj, "tokenInitData", _verifyTokenInitData);
        _vm.writeJson(json, _auxPath(block.chainid));
    }

    /// @notice Read the recorded (timelock, pool) for a chain; returns (0,0) if not yet deployed.
    function _readAux(uint256 chainId) internal view returns (address timelock, address pool) {
        string memory path = _auxPath(chainId);
        if (!_vm.exists(path)) return (address(0), address(0));
        string memory json = _vm.readFile(path);
        timelock = _vm.parseJsonAddress(json, ".timelock");
        pool = _vm.parseJsonAddress(json, ".pool");
    }

    /// @notice Read just the recorded pool for a chain (reverts if the aux record is missing).
    function _readDeployedPool(uint256 chainId) internal view returns (address pool) {
        (, pool) = _readAux(chainId);
        require(pool != address(0), "HarborTide: no recorded pool for chain");
    }
}
