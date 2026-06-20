// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {HarborTideToken_v1} from "@tide/token/HarborTideToken_v1.sol";
import {IHarborTideToken} from "@tide/token/interfaces/IHarborTideToken.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

import {MockERC20} from "@tide-test/mocks/MockERC20.sol";
import {HarborTideTokenV2Mock} from "@tide-test/mocks/HarborTideTokenV2Mock.sol";

contract HarborTideTokenV1Test is Test {
    /// @dev `Unauthorized()` selector used by bao-base role/owner gating.
    bytes4 internal constant UNAUTHORIZED = 0x82b42900;

    HarborTideToken_v1 internal token;

    address internal multisig = makeAddr("multisig");
    address internal minter = makeAddr("minter");
    address internal ccipPool = makeAddr("ccipPool");
    address internal burner = makeAddr("burner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal MAX_SUPPLY;
    uint256 internal MINTER_ROLE;
    uint256 internal BURNER_ROLE;
    uint256 internal CCIP_MINTER_ROLE;

    /// @dev Deploys a fresh proxy. The test contract is the (temporary) owner so it can grant roles.
    function _deploy(address mintTo, uint256 mintAmount) internal returns (HarborTideToken_v1) {
        address impl = address(new HarborTideToken_v1());
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (address(this), address(this), "Harbor Tide", "TIDE", mintTo, mintAmount)
        );
        return HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));
    }

    function setUp() public {
        token = _deploy(address(0), 0);
        MAX_SUPPLY = token.MAX_SUPPLY();
        MINTER_ROLE = token.MINTER_ROLE();
        BURNER_ROLE = token.BURNER_ROLE();
        CCIP_MINTER_ROLE = token.CCIP_MINTER_ROLE();
    }

    // --------------------------------------------------------------------- //
    // Metadata / initial state
    // --------------------------------------------------------------------- //

    function test_initialState() public view {
        assertEq(token.name(), "Harbor Tide");
        assertEq(token.symbol(), "TIDE");
        assertEq(token.decimals(), 18);
        assertEq(MAX_SUPPLY, 1_000_000_000e18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.owner(), address(this));
        assertEq(token.getCCIPAdmin(), address(this));
    }

    function test_initialMint_homeChain() public {
        HarborTideToken_v1 home = _deploy(multisig, MAX_SUPPLY);
        assertEq(home.totalSupply(), MAX_SUPPLY);
        assertEq(home.balanceOf(multisig), MAX_SUPPLY);
        console.log("Initial TIDE minted: %s TIDE to multisig %s", home.totalSupply() / 1e18, multisig);
    }

    function test_initialMint_aboveCap_reverts() public {
        address impl = address(new HarborTideToken_v1());
        bytes memory initData = abi.encodeCall(
            HarborTideToken_v1.initialize, (address(this), address(this), "Harbor Tide", "TIDE", multisig, MAX_SUPPLY + 1)
        );
        vm.expectRevert(abi.encodeWithSelector(IHarborTideToken.ExceedsMaxSupply.selector, MAX_SUPPLY + 1, MAX_SUPPLY));
        new ERC1967Proxy(impl, initData);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        token.initialize(address(this), address(this), "x", "x", address(0), 0);
    }

    // --------------------------------------------------------------------- //
    // Minting: roles + cap
    // --------------------------------------------------------------------- //

    function test_mint_requiresRole() public {
        vm.prank(minter);
        vm.expectRevert(UNAUTHORIZED);
        token.mint(alice, 1e18);
    }

    function test_mint_withMinterRole() public {
        token.grantRoles(minter, MINTER_ROLE);
        vm.prank(minter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_mint_withCcipMinterRole() public {
        token.grantRoles(ccipPool, CCIP_MINTER_ROLE);
        vm.prank(ccipPool);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_mint_respectsCap() public {
        token.grantRoles(minter, MINTER_ROLE);
        vm.prank(minter);
        token.mint(alice, MAX_SUPPLY);
        assertEq(token.totalSupply(), MAX_SUPPLY);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IHarborTideToken.ExceedsMaxSupply.selector, MAX_SUPPLY + 1, MAX_SUPPLY));
        token.mint(alice, 1);
    }

    /// @notice Full mint to the 1bn cap, burn 1M, then re-mint 1M back to the cap (with logging).
    function test_fullMint_burn1M_remint1M() public {
        uint256 oneMillion = 1_000_000e18;
        token.grantRoles(minter, MINTER_ROLE);
        token.grantRoles(burner, BURNER_ROLE);

        // Full mint of the entire 1bn supply (to the burner so it has tokens to burn).
        vm.prank(minter);
        token.mint(burner, MAX_SUPPLY);
        assertEq(token.totalSupply(), MAX_SUPPLY);
        console.log("1) full mint   -> totalSupply = %s TIDE", token.totalSupply() / 1e18);

        // Burn 1,000,000 TIDE.
        vm.prank(burner);
        token.burn(oneMillion);
        assertEq(token.totalSupply(), MAX_SUPPLY - oneMillion);
        assertEq(token.balanceOf(burner), MAX_SUPPLY - oneMillion);
        console.log("2) burn 1M     -> totalSupply = %s TIDE (burned 1000000)", token.totalSupply() / 1e18);

        // Re-mint 1,000,000 TIDE back up to the cap (allowed because burning freed cap headroom).
        vm.prank(minter);
        token.mint(alice, oneMillion);
        assertEq(token.totalSupply(), MAX_SUPPLY);
        assertEq(token.balanceOf(alice), oneMillion);
        console.log("3) re-mint 1M  -> totalSupply = %s TIDE (back at cap)", token.totalSupply() / 1e18);
    }

    function test_mint_canReachCapAgainAfterBurn() public {
        token.grantRoles(minter, MINTER_ROLE);
        token.grantRoles(burner, BURNER_ROLE);

        vm.prank(minter);
        token.mint(burner, MAX_SUPPLY);

        vm.prank(burner);
        token.burn(10e18);
        assertEq(token.totalSupply(), MAX_SUPPLY - 10e18);

        vm.prank(minter);
        token.mint(alice, 10e18);
        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    // --------------------------------------------------------------------- //
    // Burning: roles + CCT surface
    // --------------------------------------------------------------------- //

    function test_burn_requiresRole() public {
        token.grantRoles(minter, MINTER_ROLE);
        vm.prank(minter);
        token.mint(alice, 50e18);

        vm.prank(alice);
        vm.expectRevert(UNAUTHORIZED);
        token.burn(1e18);
    }

    function test_burn_self() public {
        token.grantRoles(minter, MINTER_ROLE);
        token.grantRoles(burner, BURNER_ROLE);
        vm.prank(minter);
        token.mint(burner, 50e18);

        vm.prank(burner);
        token.burn(20e18);
        assertEq(token.balanceOf(burner), 30e18);
        assertEq(token.totalSupply(), 30e18);
    }

    function test_burnFrom_withAllowance() public {
        token.grantRoles(minter, MINTER_ROLE);
        token.grantRoles(burner, BURNER_ROLE);
        vm.prank(minter);
        token.mint(alice, 50e18);

        vm.prank(alice);
        token.approve(burner, 30e18);

        vm.prank(burner);
        token.burnFrom(alice, 30e18);
        assertEq(token.balanceOf(alice), 20e18);
    }

    /// @dev The Chainlink CCT `burn(address,uint256)` overload (used by BurnFromMintTokenPool).
    function test_ccipBurnOverload_withAllowance() public {
        token.grantRoles(minter, MINTER_ROLE);
        token.grantRoles(ccipPool, BURNER_ROLE);
        vm.prank(minter);
        token.mint(alice, 50e18);

        vm.prank(alice);
        token.approve(ccipPool, 40e18);

        vm.prank(ccipPool);
        token.burn(alice, 40e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), 10e18);
    }

    function test_ccipBurnOverload_requiresRole() public {
        token.grantRoles(minter, MINTER_ROLE);
        vm.prank(minter);
        token.mint(alice, 50e18);
        vm.prank(alice);
        token.approve(bob, 40e18);

        vm.prank(bob);
        vm.expectRevert(UNAUTHORIZED);
        token.burn(alice, 40e18);
    }

    // --------------------------------------------------------------------- //
    // Ownership / CCIP admin
    // --------------------------------------------------------------------- //

    function test_getCCIPAdmin_tracksOwner() public {
        // Deploy with this test as the explicit deployer (temp owner) and the multisig as the *final* owner.
        address impl = address(new HarborTideToken_v1());
        bytes memory initData =
            abi.encodeCall(HarborTideToken_v1.initialize, (address(this), multisig, "Harbor Tide", "TIDE", address(0), 0));
        HarborTideToken_v1 t = HarborTideToken_v1(address(new ERC1967Proxy(impl, initData)));

        assertEq(t.owner(), address(this));
        assertEq(t.getCCIPAdmin(), address(this));

        // Complete the HarborOwnable ownership handover to the multisig.
        t.transferOwnership(multisig);
        assertEq(t.owner(), multisig);
        assertEq(t.getCCIPAdmin(), multisig);
    }

    function test_grantRoles_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(UNAUTHORIZED);
        token.grantRoles(minter, MINTER_ROLE);
    }

    // --------------------------------------------------------------------- //
    // rescueERC20
    // --------------------------------------------------------------------- //

    function test_rescueERC20() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(token), 1_000e18);

        token.rescueERC20(address(stray), bob, 1_000e18);
        assertEq(stray.balanceOf(bob), 1_000e18);
    }

    function test_rescueERC20_onlyOwner() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(token), 1_000e18);

        vm.prank(alice);
        vm.expectRevert(UNAUTHORIZED);
        token.rescueERC20(address(stray), alice, 1_000e18);
    }

    // --------------------------------------------------------------------- //
    // UUPS upgrade
    // --------------------------------------------------------------------- //

    function test_upgrade_preservesStateAndOwner() public {
        token.grantRoles(minter, MINTER_ROLE);
        vm.prank(minter);
        token.mint(alice, 123e18);

        address v2 = address(new HarborTideTokenV2Mock());
        token.upgradeToAndCall(v2, "");

        assertEq(HarborTideTokenV2Mock(address(token)).version(), 2);
        assertEq(token.balanceOf(alice), 123e18);
        assertEq(token.owner(), address(this));
    }

    function test_upgrade_onlyOwner() public {
        address v2 = address(new HarborTideTokenV2Mock());
        vm.prank(alice);
        vm.expectRevert();
        token.upgradeToAndCall(v2, "");
    }

    // --------------------------------------------------------------------- //
    // ERC165
    // --------------------------------------------------------------------- //

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Permit).interfaceId));
        assertTrue(token.supportsInterface(type(IMintable).interfaceId));
        assertTrue(token.supportsInterface(type(IBurnable).interfaceId));
        assertTrue(token.supportsInterface(type(IBurnableFrom).interfaceId));
        assertTrue(token.supportsInterface(type(IMintableRole).interfaceId));
        assertTrue(token.supportsInterface(type(IBurnableRole).interfaceId));
        assertTrue(token.supportsInterface(type(IHarborTideToken).interfaceId));
        assertFalse(token.supportsInterface(0xffffffff));
    }
}
