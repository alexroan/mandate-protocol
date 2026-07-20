// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Signatures {
    /// @dev Contract accounts are verified exclusively through ERC-1271. EOAs additionally support
    /// EIP-2098 compact signatures and 0/1-v normalization before ordinary ECDSA verification.
    function _isValidSignatureNow(address signer, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        bytes memory signatureMem = signature;
        if (signer.code.length != 0) {
            return SignatureChecker.isValidERC1271SignatureNow(signer, digest, signatureMem);
        }
        if (signature.length == 64 && _isValidCompactEOASignature(signer, digest, signature)) return true;
        if (signature.length == 65) _normalizeZeroOneV(signatureMem);
        return SignatureChecker.isValidSignatureNow(signer, digest, signatureMem);
    }

    function _normalizeZeroOneV(bytes memory signature) internal pure {
        uint8 v = uint8(signature[64]);
        if (v < 27) signature[64] = bytes1(v + 27);
    }

    function _isValidCompactEOASignature(address signer, bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (bool)
    {
        bytes32 r;
        bytes32 vs;
        assembly {
            r := calldataload(signature.offset)
            vs := calldataload(add(signature.offset, 0x20))
        }
        (address recovered, ECDSA.RecoverError error, bytes32 errorArg) = ECDSA.tryRecover(digest, r, vs);
        return error == ECDSA.RecoverError.NoError && errorArg == bytes32(0) && recovered == signer;
    }
}
