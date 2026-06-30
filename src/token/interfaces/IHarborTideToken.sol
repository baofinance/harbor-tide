// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IHarborTideToken
/// @notice Harbor Tide-specific surface on top of the standard mintable/burnable ERC20:
///         the 1bn hard cap, the CCIP minter role, the CCIP Token Admin getter, the
///         Chainlink CCT `burn(address,uint256)` overload, and an ERC20 rescue helper.
/// @dev We intentionally do NOT inherit Chainlink's `IBurnMintERC20` because that interface
///      extends a vendored OpenZeppelin v4.8.3 `IERC20`, which clashes with the OZ v5 `IERC20`
///      inherited via `ERC20Upgradeable`. CCIP pools call the token by selector, so implementing
///      the matching signatures here is sufficient for full Burn & Mint / BurnFrom & Mint support.
interface IHarborTideToken {
    /// @notice Thrown when a mint would push total supply above the hard cap.
    /// @param attempted The total supply that would result from the mint.
    /// @param cap The immutable hard cap (`MAX_SUPPLY`).
    error ExceedsMaxSupply(uint256 attempted, uint256 cap);

    /// @notice The immutable hard cap on total supply (across this chain).
    // solhint-disable-next-line func-name-mixedcase
    function MAX_SUPPLY() external view returns (uint256);

    /// @notice Role held by the Chainlink CCIP token pool; permits cross-chain mint.
    // solhint-disable-next-line func-name-mixedcase
    function CCIP_MINTER_ROLE() external view returns (uint256);

    /// @notice Chainlink CCT token administrator address (used by `RegistryModuleOwnerCustom`).
    /// @dev Returns the token owner (the Harbor multisig).
    function getCCIPAdmin() external view returns (address);

    /// @notice Burn `amount` of tokens held by `account`, spending the caller's allowance.
    /// @dev Part of Chainlink's CCT `IBurnMintERC20` surface; enables `BurnFromMintTokenPool`.
    function burn(address account, uint256 amount) external;

    /// @notice Recover unrelated ERC20 tokens accidentally sent to this contract.
    /// @param token The ERC20 token to recover.
    /// @param to The recipient of the recovered tokens.
    /// @param amount The amount to recover.
    function rescueERC20(address token, address to, uint256 amount) external;
}
