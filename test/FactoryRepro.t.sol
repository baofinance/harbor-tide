// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {BaoFactory_v1} from "@bao-factory/BaoFactory_v1.sol";
import {UUPSProxyDeployStub, IUUPSUpgradeableProxy} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {TideDeployProxy} from "@tide-script/src/TideDeployProxy.sol";
import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";

/// @notice Local (no-fork) regression for the via-stub CREATE3 deploy against the *real* BaoFactory_v1
///         implementation. Guards against the OpenZeppelin v5.6.0 `ERC1967ProxyUninitialized()` revert:
///         the via-stub deploy must use `TideDeployProxy` (empty-init allowed), not OZ `ERC1967Proxy`.
contract FactoryReproTest is Test {
    address internal constant FACTORY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    function test_viaStubDeploy_initializesAndOwns() public {
        BaoFactory_v1 factory = new BaoFactory_v1();
        bytes32 salt = keccak256("harbor_tide_v1::token");
        address predicted = factory.predictAddress(salt);

        // All calls originate from the factory owner so msg.sender during init == the deployer EOA.
        vm.startPrank(FACTORY_OWNER);

        UUPSProxyDeployStub stub = new UUPSProxyDeployStub();
        bytes memory initCode =
            abi.encodePacked(type(TideDeployProxy).creationCode, abi.encode(address(stub), bytes("")));
        address proxy = factory.deploy(initCode, salt);
        assertEq(proxy, predicted, "deployed address != predicted");

        HarborTideToken_v1 impl = new HarborTideToken_v1();
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (FACTORY_OWNER, "Harbor Tide", "TIDE", FACTORY_OWNER, 0)
        );
        IUUPSUpgradeableProxy(proxy).upgradeToAndCall(address(impl), initData);

        vm.stopPrank();

        HarborTideToken_v1 token = HarborTideToken_v1(proxy);
        assertEq(token.owner(), FACTORY_OWNER, "temp owner != deployer EOA");
        assertEq(token.symbol(), "TIDE");
        console.log("via-stub deploy OK: proxy %s owner %s", proxy, token.owner());
    }
}
