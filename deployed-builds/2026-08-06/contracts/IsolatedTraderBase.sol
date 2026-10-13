// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/**
 * @title IsolatedTraderBase
 * @notice Small shared base with EIP-712 helpers and flag helpers. No storage.
 */
abstract contract IsolatedTraderBase {
    /**
     * @dev Computes EIP-712 domain separator hash.
     */
    function computeDomainHash(
        string memory name,
        string memory version,
        uint256 chainId,
        address verifyingContract
    ) internal pure returns (bytes32) {
        bytes32 schemaHash = keccak256(
            abi.encodePacked(
                "EIP712Domain(",
                "string name,",
                "string version,",
                "uint256 chainId,",
                "address verifyingContract",
                ")"
            )
        );

        return
            keccak256(
                abi.encode(
                    schemaHash,
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    chainId,
                    verifyingContract
                )
            );
    }

    /**
     * @dev Packs EIP-191 prefix with domain hash and struct hash to compute final digest.
     */
    function computeEIP712MessageHash(bytes32 domainHash, bytes32 structHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(bytes2(0x1901), domainHash, structHash));
    }

    /**
     * @dev Returns true if the flags indicate a BUY order.
     */
    function isBuyFlag(bytes8 flags) internal pure returns (bool) {
        return (flags & bytes8(bytes32(uint256(1 << 192)))) != bytes8(0);
    }

    /**
     * @dev Returns true if the flags indicate a REDUCE-ONLY order.
     */
    function isReduceOnlyFlag(bytes8 flags) internal pure returns (bool) {
        return (flags & bytes8(bytes32(uint256(1 << 193)))) != bytes8(0);
    }

    /**
     * @dev Returns true if the flags indicate a protocol-forced liquidation
     * order. Forced liquidation orders are unsigned and must be reduce-only.
     */
    function isForcedLiquidationFlag(bytes8 flags) internal pure returns (bool) {
        return (flags & bytes8(bytes32(uint256(1 << 194)))) != bytes8(0);
    }

}
