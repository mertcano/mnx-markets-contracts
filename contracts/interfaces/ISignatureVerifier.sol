// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {TypedSignature} from '../libraries/TypedSignature.sol';

/**
 * @title ISignatureVerifier
 * @notice Interface for stateless EIP-712 signature verification
 * @dev This contract is stateless - nonce management remains in the calling contract
 */
interface ISignatureVerifier {
  /**
   * @notice Recovers the signer address from a margin adjustment signature
   * @param perpetual The address of the Perpetual contract (used as verifyingContract in EIP-712 domain)
   * @param account The account address for which margin is being adjusted
   * @param amount The amount of margin being added or removed
   * @param isAddition True if adding margin, false if removing
   * @param nonce Unique nonce to prevent replay attacks
   * @param deadline Last block timestamp at which the authorization is valid
   * @param signature The EIP-712 signature
   * @return signer The recovered address, or address(0) when ECDSA recovery
   *  fails (including a high-s signature). Reverts with a Panic when the
   *  signature-type byte is not 0, 1 or 2.
   */
  function recoverMarginSigner(
    address perpetual,
    address account,
    uint128 amount,
    bool isAddition,
    uint128 nonce,
    uint64 deadline,
    TypedSignature.Signature calldata signature
  ) external view returns (address signer);

  /**
   * @notice Recovers the signer address from a flexible remove-margin signature
   * @param perpetual The address of the Perpetual contract (used as verifyingContract in EIP-712 domain)
   * @param account The account address for which margin is being removed
   * @param maxAmount The maximum amount the signer authorizes removing
   * @param minAmount The minimum amount that must be removed for the transaction to succeed
   * @param nonce Unique nonce to prevent replay attacks
   * @param deadline Last block timestamp at which the authorization is valid
   * @param signature The EIP-712 signature
   * @return signer The recovered address, or address(0) when ECDSA recovery
   *  fails (including a high-s signature). Reverts with a Panic when the
   *  signature-type byte is not 0, 1 or 2.
   */
  function recoverRemoveMarginUpToSigner(
    address perpetual,
    address account,
    uint128 maxAmount,
    uint128 minAmount,
    uint128 nonce,
    uint64 deadline,
    TypedSignature.Signature calldata signature
  ) external view returns (address signer);

  /**
   * @notice Recovers the signer address from a leverage adjustment signature
   * @param perpetual The address of the Perpetual contract (used as verifyingContract in EIP-712 domain)
   * @param account The account address for which leverage is being adjusted
   * @param leverage The new leverage value
   * @param maxMarginIn Maximum collateral the signer authorizes moving from
   *  their MarginBank balance into the position for this adjustment
   * @param minMarginOut Minimum collateral the signer requires moving from the
   *  position back into their MarginBank balance for this adjustment
   * @param nonce Unique nonce to prevent replay attacks
   * @param deadline Last block timestamp at which the authorization is valid
   * @param signature The EIP-712 signature
   * @return signer The recovered address, or address(0) when ECDSA recovery
   *  fails (including a high-s signature). Reverts with a Panic when the
   *  signature-type byte is not 0, 1 or 2.
   */
  function recoverLeverageSigner(
    address perpetual,
    address account,
    uint128 leverage,
    uint128 maxMarginIn,
    uint128 minMarginOut,
    uint128 nonce,
    uint64 deadline,
    TypedSignature.Signature calldata signature
  ) external view returns (address signer);

  /**
   * @notice Recovers the signer address from a MarginBank withdrawal signature
   * @param marginBank The MarginBank address (used as verifyingContract in EIP-712 domain)
   * @param owner The account whose bank balance is being withdrawn
   * @param destination The address receiving the withdrawn tokens
   * @param amount The gross amount debited from MarginBank, in token decimals
   * @param minimumAmountOut The minimum amount the destination must receive after fees
   * @param nonce Current per-owner withdrawal nonce to prevent replay attacks
   * @param deadline Last timestamp at which the authorization is valid
   * @param signature The EIP-712 signature
   * @return signer The recovered address, or address(0) when ECDSA recovery
   *  fails (including a high-s signature). Reverts with a Panic when the
   *  signature-type byte is not 0, 1 or 2.
   */
  function recoverWithdrawalSigner(
    address marginBank,
    address owner,
    address destination,
    uint128 amount,
    uint128 minimumAmountOut,
    uint128 nonce,
    uint64 deadline,
    TypedSignature.Signature calldata signature
  ) external view returns (address signer);
}
