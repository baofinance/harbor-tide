// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {HarborTideFactoryDeployer} from "@tide-script/src/HarborTideFactoryDeployer.sol";

/// @dev Concrete harness exposing the internal state/aux helpers for testing.
contract TideDeployerHarness is HarborTideFactoryDeployer {
    function hasToken() external view returns (bool) {
        return DeploymentState.hasProxy(_loadState(), "token");
    }

    /// @notice Record a token proxy in the canonical state and persist it (mirrors the deploy step).
    function recordTokenAndSave(address proxy, address impl) external {
        DeploymentTypes.State memory s = _loadState();
        _recordImplementation(s, "token", "HarborTideToken_v1.sol", "HarborTideToken_v1", impl);
        DeploymentState.recordProxy(
            s,
            DeploymentTypes.ProxyRecord({
                id: "token",
                proxy: proxy,
                implementation: impl,
                salt: SALT_PREFIX,
                deploymentTime: uint64(block.timestamp)
            })
        );
        _saveState(s);
    }

    function writeAux(address token, address timelock, address pool) external {
        _writeAux(token, timelock, pool);
    }

    function readAux(uint256 chainId) external view returns (address, address) {
        return _readAux(chainId);
    }

    function readDeployedPool(uint256 chainId) external view returns (address) {
        return _readDeployedPool(chainId);
    }

    function statePath() external view returns (string memory) {
        return _stateFileWrite();
    }

    function auxPath(uint256 chainId) external view returns (string memory) {
        return _auxPath(chainId);
    }
}

/// @notice Validates the harbor-style state-driven deploy bookkeeping: a state file + a companion aux
///         deployment file are produced, are readable by later scripts, and gate re-runs idempotently.
contract StateDeployTest is Test {
    TideDeployerHarness internal deployer;

    address internal constant TOKEN = address(0x7111);
    address internal constant IMPL = address(0x1117);
    address internal constant TIMELOCK = address(0x7117);
    address internal constant POOL = address(0x9001);

    function setUp() public {
        deployer = new TideDeployerHarness();
    }

    function _cleanup() internal {
        string memory sp = deployer.statePath();
        if (vm.exists(sp)) vm.removeFile(sp);
        string memory ap = deployer.auxPath(block.chainid);
        if (vm.exists(ap)) vm.removeFile(ap);
    }

    function test_stateFile_recordsTokenAndIsIdempotent() public {
        // Forge runs test fns concurrently with a shared filesystem; use a unique chainId so this
        // test's state/aux paths never collide with another test's.
        vm.chainId(424201);
        _cleanup();

        assertFalse(deployer.hasToken(), "token should be absent before deploy");

        deployer.recordTokenAndSave(TOKEN, IMPL);

        // The canonical state file now exists and reports the token (so a re-run skips it).
        assertTrue(vm.exists(deployer.statePath()), "state file not written");
        assertTrue(deployer.hasToken(), "token should be recorded in state");
        _cleanup();
    }

    function test_auxFile_roundTripsTimelockAndPool() public {
        vm.chainId(424202);
        _cleanup();

        // Missing aux => (0,0), which is what gates the timelock/pool deploy step.
        (address tl0, address p0) = deployer.readAux(block.chainid);
        assertEq(tl0, address(0));
        assertEq(p0, address(0));

        deployer.writeAux(TOKEN, TIMELOCK, POOL);

        (address tl1, address p1) = deployer.readAux(block.chainid);
        assertEq(tl1, TIMELOCK, "timelock mismatch");
        assertEq(p1, POOL, "pool mismatch");
        assertEq(deployer.readDeployedPool(block.chainid), POOL, "pool reader mismatch");
        _cleanup();
    }
}
