// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';

/**
 * @notice Trusted-relayer forwarder for the gasless transaction signing flow.
 */
contract MNXMinimalForwarder is EIP712, Ownable2Step {
  using ECDSA for bytes32;

  struct ForwardRequest {
    address from;
    address to;
    uint256 gas;
    uint256 nonce;
    uint256 deadline;
    bytes data;
  }

  bytes32 private constant TYPEHASH =
    keccak256(
      'ForwardRequest(address from,address to,uint256 gas,uint256 nonce,uint256 deadline,bytes data)'
    );

  mapping(address => uint256) private nonces;
  mapping(address => bool) public relayers;

  event RelayerUpdate(address indexed relayer, bool approved);

  constructor() EIP712('MinimalForwarder', '0.0.2') Ownable(msg.sender) {}

  function getNonce(address from) public view returns (uint256) {
    return nonces[from];
  }

  function setRelayer(address relayer, bool approved) external onlyOwner {
    require(relayer != address(0), 'MinimalForwarder: invalid relayer');
    relayers[relayer] = approved;
    emit RelayerUpdate(relayer, approved);
  }

  function verify(
    ForwardRequest calldata req,
    bytes calldata signature
  ) public view returns (bool) {
    require(block.timestamp <= req.deadline, 'MinimalForwarder: expired');

    address signer = _hashTypedDataV4(
      keccak256(
        abi.encode(
          TYPEHASH,
          req.from,
          req.to,
          req.gas,
          req.nonce,
          req.deadline,
          keccak256(req.data)
        )
      )
    ).recover(signature);
    return nonces[req.from] == req.nonce && signer == req.from;
  }

  function execute(
    ForwardRequest calldata req,
    bytes calldata signature
  ) public returns (bytes memory) {
    require(relayers[msg.sender], 'MinimalForwarder: caller not relayer');
    require(block.timestamp <= req.deadline, 'MinimalForwarder: expired');
    require(
      verify(req, signature),
      'MinimalForwarder: signature does not match request'
    );
    nonces[req.from] = req.nonce + 1;

    (bool success, bytes memory returndata) = req.to.call{gas: req.gas}(
      abi.encodePacked(req.data, req.from)
    );

    if (gasleft() <= req.gas / 63) {
      /// @solidity memory-safe-assembly
      assembly {
        invalid()
      }
    }

    if (!success) {
      if (returndata.length == 0) {
        revert('MinimalForwarder: target call failed');
      }

      /// @solidity memory-safe-assembly
      assembly {
        revert(add(returndata, 0x20), mload(returndata))
      }
    }

    return returndata;
  }
}
