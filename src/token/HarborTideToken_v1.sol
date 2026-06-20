// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

import {IHarborTideToken} from "@tide/token/interfaces/IHarborTideToken.sol";

/// @title Harbor Tide token
/// @notice Upgradeable (UUPS), hard-capped, mintable/burnable ERC20 with Chainlink CCIP (CCT)
///         omnichain support. Modeled on bao-base `MintableBurnableERC20_v1` (Sherlock-audited),
///         with three additions: a 1bn hard cap, a separate `CCIP_MINTER_ROLE` for the CCIP token
///         pool, and the Chainlink CCT admin/burn surface (`getCCIPAdmin`, `burn(address,uint256)`).
/// @dev Roles are inherited from bao-base. Governance minting is gated by `MINTER_ROLE`, which is
///      granted to an external timelock (the "no surprise mints" delay lives outside this token).
///      The CCIP token pool holds `CCIP_MINTER_ROLE` (and `BURNER_ROLE`); CCIP cannot create new
///      supply, it only re-materializes tokens burned on another chain, so the cap is never the
///      thing that issues new supply - it is a safety invariant. Deployed via BaoFactory (CREATE3)
///      so the proxy shares one address across all chains; the initial 1bn is minted only on the
///      home chain.
/// @dev `MAX_SUPPLY` is enforced against this chain's `totalSupply()`, i.e. it is a *per-chain* cap.
///      The 1bn remains a true *global* cap because (a) `MINTER_ROLE` is granted only on the home
///      chain, where supply already starts at the cap, and (b) remote chains receive supply solely
///      via CCIP, which is bounded by burns on other chains. Do NOT grant `MINTER_ROLE` on remote
///      chains, or governance could mint new supply beyond the global 1bn.
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-capwords
contract HarborTideToken_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20PermitUpgradeable,
    ERC20BurnableUpgradeable,
    HarborOwnableRoles,
    IMintable,
    IBurnable,
    IBurnableFrom,
    IMintableRole,
    IBurnableRole,
    IHarborTideToken
{
    using SafeERC20 for IERC20;

    /// @inheritdoc IHarborTideToken
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    /// @inheritdoc IMintableRole
    uint256 public constant MINTER_ROLE = _ROLE_0;

    /// @inheritdoc IBurnableRole
    uint256 public constant BURNER_ROLE = _ROLE_1;

    /// @inheritdoc IHarborTideToken
    uint256 public constant CCIP_MINTER_ROLE = _ROLE_2;

    /// @notice In UUPS proxies the constructor only stops the implementation being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the UUPS proxy.
    /// @param deployerOwner The temporary owner during deploy (the deployer EOA) that grants roles and
    ///        completes the handover. `HarborOwnable` takes this *explicitly* rather than reading
    ///        `msg.sender`, so the proxy can be CREATE3-deployed directly via BaoFactory (no via-stub
    ///        and no empty-init proxy workaround needed).
    /// @param owner_ The address the owner is expected to be after a transferOwnership during deploy.
    /// @param name_ The name of the ERC20 token.
    /// @param symbol_ The symbol of the ERC20 token.
    /// @param initialMintTo Recipient of the initial mint (the multisig on the home chain).
    /// @param initialMintAmount Amount to mint at init - the full 1bn on the home chain, 0 on remote chains.
    function initialize(
        address deployerOwner,
        address owner_,
        string memory name_,
        string memory symbol_,
        address initialMintTo,
        uint256 initialMintAmount
    ) public initializer {
        _initializeOwner(deployerOwner, owner_);
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        if (initialMintAmount > 0) {
            if (initialMintAmount > MAX_SUPPLY) revert ExceedsMaxSupply(initialMintAmount, MAX_SUPPLY);
            _mint(initialMintTo, initialMintAmount);
        }
    }

    /// @notice Only owners can upgrade this contract (UUPS).
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @inheritdoc IMintable
    /// @dev `MINTER_ROLE` is held by the governance timelock; `CCIP_MINTER_ROLE` by the CCIP pool.
    ///      Both paths are bounded by the hard cap.
    function mint(address to, uint256 amount) public override onlyRoles(MINTER_ROLE | CCIP_MINTER_ROLE) {
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > MAX_SUPPLY) revert ExceedsMaxSupply(newSupply, MAX_SUPPLY);
        _mint(to, amount);
    }

    /// @inheritdoc IBurnable
    function burn(uint256 amount) public override(IBurnable, ERC20BurnableUpgradeable) onlyRoles(BURNER_ROLE) {
        super.burn(amount);
    }

    /// @inheritdoc IBurnableFrom
    function burnFrom(address from, uint256 amount)
        public
        override(IBurnableFrom, ERC20BurnableUpgradeable)
        onlyRoles(BURNER_ROLE)
    {
        super.burnFrom(from, amount);
    }

    /// @inheritdoc IHarborTideToken
    /// @dev Chainlink CCT `IBurnMintERC20` overload (enables `BurnFromMintTokenPool`); routes to the
    ///      allowance-checked burn.
    function burn(address from, uint256 amount) public override onlyRoles(BURNER_ROLE) {
        super.burnFrom(from, amount);
    }

    /// @inheritdoc IHarborTideToken
    function getCCIPAdmin() external view returns (address) {
        return owner();
    }

    /// @inheritdoc IHarborTideToken
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @inheritdoc HarborOwnableRoles
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IMintableRole).interfaceId || interfaceId == type(IBurnableRole).interfaceId
            || interfaceId == type(IMintable).interfaceId || interfaceId == type(IBurnable).interfaceId
            || interfaceId == type(IBurnableFrom).interfaceId || interfaceId == type(IHarborTideToken).interfaceId
            || interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId
            || interfaceId == type(IERC20Permit).interfaceId || super.supportsInterface(interfaceId);
    }
}
