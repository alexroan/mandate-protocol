// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IUnorderedNonces} from "./interfaces/IUnorderedNonces.sol";

contract UnorderedNonces is IUnorderedNonces {
    /// @inheritdoc IUnorderedNonces
    mapping(address owner => mapping(uint248 wordPos => uint256 bitmap)) public nonceBitmap;

    /// @inheritdoc IUnorderedNonces
    function invalidateUnorderedNonces(uint248 wordPos, uint256 mask) external {
        nonceBitmap[msg.sender][wordPos] |= mask;
        emit UnorderedNonceInvalidation(msg.sender, wordPos, mask);
    }

    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        // Safe: shifting right by 8 leaves at most 248 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint248 wordPos = uint248(nonce >> 8);
        // Intentional: the low 8 bits select the bit inside the nonce bitmap word.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 bitPos = uint8(nonce);
        uint256 bit = uint256(1) << bitPos;
        uint256 bitmap = nonceBitmap[owner][wordPos];
        if (bitmap & bit != 0) revert InvalidUnorderedNonce();
        nonceBitmap[owner][wordPos] = bitmap | bit;
    }
}
