// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaoFactory_v1} from "@bao-factory/BaoFactory_v1.sol";
import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";

/// @notice Local (no-fork) regression for the direct CREATE3 deploy against the *real* BaoFactory_v1
///         implementation. Because `HarborOwnableRoles` takes the deployer explicitly, the proxy is a
///         plain OZ `ERC1967Proxy(impl, initData)` deployed in one step — no via-stub, and no custom
///         empty-init proxy. The deploy is driven by the factory owner, but the explicit `deployerOwner`
///         arg (a *different* address) becomes the temp owner — proving the owner is the explicit arg,
///         not the CREATE3 caller. This is exactly what removes the need for the stub.
contract FactoryReproTest is Test {
    /// @dev BaoFactory_v1's baked-in owner (authorized to call `deploy`).
    address internal constant FACTORY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    /// @dev Distinct explicit deployer/temp owner, separate from the CREATE3 caller.
    address internal deployer = makeAddr("deployer");
    address internal finalOwner = makeAddr("finalOwner");

    function test_directDeploy_initializesWithExplicitOwner() public {
        BaoFactory_v1 factory = new BaoFactory_v1();
        bytes32 salt = keccak256("harbor_tide_v1::token");
        address predicted = factory.predictAddress(salt);

        HarborTideToken_v1 impl = new HarborTideToken_v1();
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (deployer, finalOwner, "Harbor Tide", "TIDE", finalOwner, 0)
        );

        // The factory owner submits the CREATE3 deploy; the proxy initializes in its own constructor.
        vm.prank(FACTORY_OWNER);
        address proxy = factory.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(impl), initData)), salt
        );
        assertEq(proxy, predicted, "deployed address != predicted");

        HarborTideToken_v1 token = HarborTideToken_v1(proxy);
        // The explicit deployer arg is the temp owner — NOT msg.sender (FACTORY_OWNER) or the factory.
        assertEq(token.owner(), deployer, "temp owner != explicit deployer");
        assertEq(token.symbol(), "TIDE");

        // The temp owner (explicit deployer) completes the handover to the final owner.
        vm.prank(deployer);
        token.transferOwnership(finalOwner);
        assertEq(token.owner(), finalOwner, "owner != finalOwner after handover");
        console.log("direct deploy OK: proxy %s final owner %s", proxy, token.owner());
    }
}
