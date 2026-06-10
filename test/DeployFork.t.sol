// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {UUPSProxyDeployStub, IUUPSUpgradeableProxy} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {TideDeployProxy} from "@tide-script/src/TideDeployProxy.sol";
import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";

/// @notice End-to-end fork test of the real CREATE3 deploy against the *live* BaoFactory on Ethereum
///         mainnet, sending as the actual authorized operator. This mirrors `Deploy.s.sol`'s home-chain
///         path: via-stub proxy deploy, full 1bn mint to the multisig, timelock MINTER_ROLE grant, pool
///         role grant, and the ownership handover to the multisig.
/// @dev Skips when MAINNET_RPC_URL is unset. Asserts the operator is currently valid, so it fails loudly
///      (= "re-register the operator") if the BaoFactory authorization has lapsed.
contract DeployForkTest is Test {
    /// @notice Live BaoFactory (CREATE3) on mainnet.
    address internal constant BAO_FACTORY = 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458;

    /// @notice Authorized BaoFactory operator (valid to end of year) used as the deployer EOA.
    address internal constant OPERATOR = 0x61c533E213fE1a19975101369B9f7E7890196290;

    /// @notice Harbor multisig — final owner / CCIP admin.
    address internal constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    string internal constant SALT_PREFIX = "harbor_tide_v1";
    uint256 internal constant TIMELOCK_MIN_DELAY = 24 hours;

    function _saltFor(string memory key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, "::", key));
    }

    function test_fork_deployViaRealFactoryAsOperator() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        IBaoFactory factory = IBaoFactory(BAO_FACTORY);

        // 0. The operator must be currently authorized; otherwise re-register before deploying.
        assertTrue(
            factory.isCurrentOperator(OPERATOR),
            "OPERATOR is not a current BaoFactory operator (re-register it)"
        );
        console.log("Operator %s authorized on factory %s", OPERATOR, BAO_FACTORY);

        // 1. Deterministic token address (salt-only -> identical on every chain).
        bytes32 salt = _saltFor("token");
        address predicted = factory.predictAddress(salt);
        console.log("Predicted token address: %s", predicted);
        if (predicted.code.length != 0) {
            console.log("  already deployed at predicted address -> skipping");
            vm.skip(true);
            return;
        }

        uint256 cap = HarborTideToken_v1(address(new HarborTideToken_v1())).MAX_SUPPLY();

        // 2. Deploy exactly as Deploy.s.sol does, but with all calls originating from the operator EOA
        //    (so the factory sees msg.sender == operator, and BaoOwnable's temp owner == operator).
        vm.startPrank(OPERATOR, OPERATOR);

        UUPSProxyDeployStub stub = new UUPSProxyDeployStub();
        HarborTideToken_v1 impl = new HarborTideToken_v1();
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (HARBOR_MULTISIG, "Harbor Tide", "TIDE", HARBOR_MULTISIG, cap)
        );

        address proxy = factory.deploy(
            abi.encodePacked(type(TideDeployProxy).creationCode, abi.encode(address(stub), bytes(""))), salt
        );
        assertEq(proxy, predicted, "deployed address != predicted");

        IUUPSUpgradeableProxy(proxy).upgradeToAndCall(address(impl), initData);
        HarborTideToken_v1 token = HarborTideToken_v1(proxy);

        // Home-chain supply minted to the multisig.
        assertEq(token.totalSupply(), cap, "totalSupply != cap");
        assertEq(token.balanceOf(HARBOR_MULTISIG), cap, "multisig balance != cap");
        console.log("Minted %s TIDE to multisig %s", token.totalSupply() / 1e18, HARBOR_MULTISIG);

        // 3. Governance timelock holds MINTER_ROLE; CCIP pool (dummy here) holds CCIP_MINTER | BURNER.
        address[] memory ms = new address[](1);
        ms[0] = HARBOR_MULTISIG;
        TimelockController timelock = new TimelockController(TIMELOCK_MIN_DELAY, ms, ms, HARBOR_MULTISIG);
        token.grantRoles(address(timelock), token.MINTER_ROLE());

        address dummyPool = makeAddr("pool");
        token.grantRoles(dummyPool, token.CCIP_MINTER_ROLE() | token.BURNER_ROLE());

        // 4. Hand ownership to the multisig (within BaoOwnable's 1h window — same tx context here).
        token.transferOwnership(HARBOR_MULTISIG);

        vm.stopPrank();

        // Post-conditions.
        assertEq(token.owner(), HARBOR_MULTISIG, "owner != multisig");
        assertEq(token.getCCIPAdmin(), HARBOR_MULTISIG, "ccipAdmin != multisig");
        assertTrue(token.hasAllRoles(address(timelock), token.MINTER_ROLE()), "timelock missing MINTER_ROLE");
        assertTrue(
            token.hasAllRoles(dummyPool, token.CCIP_MINTER_ROLE() | token.BURNER_ROLE()),
            "pool missing CCIP roles"
        );
        console.log("Deploy via real factory OK: token %s owner %s", proxy, token.owner());
    }
}
