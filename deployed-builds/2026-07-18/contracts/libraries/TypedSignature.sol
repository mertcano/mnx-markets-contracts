// SPDX-License-Identifier: GPL-3.0-or-later
/*

    Copyright 2020 dYdX Trading Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/
// Modified by MNX Markets; see NOTICE.

pragma solidity 0.8.26;

import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/**
 * This contract has been largely taken from (https://github.com/dydxprotocol/perpetual/blob/master/contracts/protocol/lib/TypedSignature.sol)
 * The credit belongs to dydx.
 */
library TypedSignature {
    //
    // ENUMS
    //

    // Different RPC providers may implement signing methods differently, so we allow different
    // signature types depending on the string prepended to a hash before it was signed.
    enum SignatureType {
        NoPrepend, // No string was prepended.
        Decimal, // PREPEND_DEC was prepended.
        Hexadecimal, // PREPEND_HEX was prepended.
        Invalid // Not a valid type, and no code compares against it: type 3 fails
        // the assert in recover() (Panic 0x01), and 4+ fails the enum conversion
        // (Panic 0x21).
    }

    //
    // STRUCTS
    //

    struct Signature {
        bytes32 r;
        bytes32 s;
        bytes2 vType;
    }

    //
    // CONSTANTS
    //

    bytes32 private constant FILE = "TypedSignature";

    // Prepended message with the length of the signed hash in decimal.
    bytes private constant PREPEND_DEC = "\x19Ethereum Signed Message:\n32";

    // Prepended message with the length of the signed hash in hexadecimal.
    bytes private constant PREPEND_HEX = "\x19Ethereum Signed Message:\n\x20";

    // Number of bytes in a typed signature.
    uint128 private constant NUM_SIGNATURE_BYTES = 66;

    // ============ Functions ============

    /**
     * @dev Gives the address of the signer of a hash. Also allows for the commonly prepended string
     *  of '\x19Ethereum Signed Message:\n' + message.length
     *
     * @param  hash       Hash that was signed (does not include prepended message).
     * @param  signature  Type and ECDSA signature with structure: {32:r}{32:s}{1:v}{1:type}
     * @return            Address of the signer of the hash.
     */
    function recover(bytes32 hash, Signature memory signature)
        internal
        pure
        returns (address)
    {
        SignatureType sigType = SignatureType(
            uint8(bytes1(signature.vType << 8))
        );

        bytes32 signedHash;
        if (sigType == SignatureType.NoPrepend) {
            signedHash = hash;
        } else if (sigType == SignatureType.Decimal) {
            signedHash = keccak256(abi.encodePacked(PREPEND_DEC, hash));
        } else {
            assert(sigType == SignatureType.Hexadecimal);
            signedHash = keccak256(abi.encodePacked(PREPEND_HEX, hash));
        }

        // ECDSA.tryRecover rejects malleable signatures (s above the
        // curve-order halfway point) and returns address(0) for them, the
        // same value ecrecover returns for any other invalid signature, so
        // callers keep their existing invalid-signer error behavior.
        (address recovered, , ) = ECDSA.tryRecover(
            signedHash,
            uint8(bytes1(signature.vType)),
            signature.r,
            signature.s
        );
        return recovered;
    }
}
