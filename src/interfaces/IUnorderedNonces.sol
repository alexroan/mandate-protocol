// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IUnorderedNonces {
    /// @notice A nonce has already been used or invalidated.
    error InvalidUnorderedNonce();

    /// @notice Emitted when a payer invalidates unordered mandate nonce bits.
    /// @param owner Payer whose nonce bitmap was updated.
    /// @param wordPos Bitmap word position.
    /// @param mask Bits ORed into the nonce bitmap word.
    event UnorderedNonceInvalidation(address indexed owner, uint248 indexed wordPos, uint256 mask);

    /// @notice Returns a payer unordered mandate nonce bitmap word.
    /// @param owner Payer whose nonce bitmap is queried.
    /// @param wordPos Bitmap word position.
    /// @return bitmap Current bitmap word.
    function nonceBitmap(address owner, uint248 wordPos) external view returns (uint256);

    /// @notice Invalidates pending mandate-opening nonces for the caller.
    /// @dev Sets `nonceBitmap[msg.sender][wordPos] |= mask`. This blocks future opens using those
    /// nonce bits but does not cancel already opened mandates. A zero mask is allowed and only emits
    /// an event.
    /// @param wordPos High 248 bits of the unordered nonce space.
    /// @param mask Bitmap mask selecting nonce bits to invalidate.
    function invalidateUnorderedNonces(uint248 wordPos, uint256 mask) external;
}
