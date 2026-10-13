// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/**
 * A base contract to be inherited by any contract that want to receive relayed transactions
 * A subclass must use "msgSender()" instead of "msg.sender"
 */
abstract contract BaseRelayRecipient {
    /*
     * Forwarder singleton we accept calls from
     */
    address public trustedForwarder;

    event TrustedForwarderUpdate(
        address indexed previousForwarder,
        address indexed newForwarder
    );

    /*
     * require a function to be called through the trusted forwarder only
     * (unused in this repository)
     */
    modifier trustedForwarderOnly() {
        require(
            msg.sender == trustedForwarder,
            "Function can only be called through the trusted Forwarder"
        );
        _;
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    function __MetaTransaction_init(address _trustedForwarder) internal {
        _setTrustedForwarder(_trustedForwarder);
    }

    /**
     * @dev A trusted forwarder is believed when it appends a sender address to
     * calldata, so `msgSender()` returns that address instead of `msg.sender`.
     * Only a deployed forwarder contract can verify the user's signature before
     * appending. A wallet, or any address without code, could append an
     * arbitrary address and impersonate that user across every recipient.
     * Requiring code is a necessary floor, not proof of safety. A malicious
     * contract still passes, and so does an EIP-7702-delegated wallet: its
     * 23-byte delegation designator is code, so an EOA that has delegated to
     * some contract satisfies this check while its private key still controls
     * the account. Reviewing the candidate's runtime bytecode before the owner
     * rotates to it remains the actual security boundary.
     */
    function _setTrustedForwarder(address _trustedForwarder) internal {
        require(
            _trustedForwarder != address(0),
            "BaseRelayRecipient: invalid trusted forwarder"
        );
        // Audit #82. The forwarder is the one address whose calldata suffix is
        // BELIEVED as the sender: msgSender() returns whatever the last 20
        // bytes say whenever msg.sender == trustedForwarder and the calldata is
        // at least 24 bytes. Rotating to an EOA or a typo'd address therefore
        // hands whoever controls that key (or nobody, forever) the power to
        // impersonate ANY account across every relayed entrypoint of this
        // contract. A contract-code check cannot prove the code is the reviewed
        // forwarder — the deployment tooling attests that — but it makes the
        // cheapest catastrophic mistakes (EOA, wrong-network address,
        // fat-fingered hex) revert at the setter instead of at the first forged
        // meta-transaction.
        require(
            _trustedForwarder.code.length > 0,
            "BaseRelayRecipient: forwarder not a contract"
        );
        address previousForwarder = trustedForwarder;
        trustedForwarder = _trustedForwarder;
        emit TrustedForwarderUpdate(previousForwarder, _trustedForwarder);
    }

    /**
     * return the sender of this call.
     * if the call came through our trusted forwarder, return the original sender.
     * otherwise, return `msg.sender`.
     * should be used in the contract anywhere instead of msg.sender
     */
    function msgSender() public view returns (address payable ret) {
        if (msg.data.length >= 24 && isTrustedForwarder(msg.sender)) {
            // At this point we know that the sender is a trusted forwarder,
            // so we trust that the last bytes of msg.data are the verified sender address.
            // extract sender address from the end of msg.data
            assembly {
                ret := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            return payable(msg.sender);
        }
    }
}
