// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";

/// @notice Validates the governance-minting model: MINTER_ROLE is held by an external
///         OpenZeppelin TimelockController, so every governance mint is delayed (the "no surprise
///         mints" guardrail) rather than baked into the token as a minting window.
contract TimelockTest is Test {
    uint256 internal constant MIN_DELAY = 24 hours;

    HarborTideToken_v1 internal token;
    TimelockController internal timelock;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");

    function setUp() public {
        address impl = address(new HarborTideToken_v1());
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (address(this), address(this), "Harbor Tide", "TIDE", address(0), 0)
        );
        token = HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));

        address[] memory controllers = new address[](1);
        controllers[0] = multisig;
        timelock = new TimelockController(MIN_DELAY, controllers, controllers, address(0));

        token.grantRoles(address(timelock), token.MINTER_ROLE());
    }

    function test_timelockMint_afterDelay() public {
        bytes memory data = abi.encodeCall(HarborTideToken_v1.mint, (alice, 1_000e18));
        bytes32 salt = bytes32("mint-1");

        vm.prank(multisig);
        timelock.schedule(address(token), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        timelock.execute(address(token), 0, data, bytes32(0), salt);

        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_timelockMint_beforeDelay_reverts() public {
        bytes memory data = abi.encodeCall(HarborTideToken_v1.mint, (alice, 1_000e18));
        bytes32 salt = bytes32("mint-2");

        vm.prank(multisig);
        timelock.schedule(address(token), 0, data, bytes32(0), salt, MIN_DELAY);

        // Not ready yet: execute should revert.
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(token), 0, data, bytes32(0), salt);

        assertEq(token.balanceOf(alice), 0);
    }

    function test_directMint_fromMultisig_reverts() public {
        // The multisig holds no MINTER_ROLE directly; only the timelock does.
        vm.prank(multisig);
        vm.expectRevert();
        token.mint(alice, 1_000e18);
    }
}
