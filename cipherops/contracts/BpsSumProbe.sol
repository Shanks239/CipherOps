// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { FHE, externalEuint16, euint16, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title BpsSumProbe
/// @notice Standalone probe to test the single technical assumption underlying
///         ConfidentialRoyalty: that the contract can verify N encrypted basis-point
///         shares sum to exactly 10,000 without learning any individual share, and
///         publicly decrypt only the boolean result.
///
/// @dev If this contract compiles, deploys, and the encrypted equality check returns
///      `true` for a valid split and `false` for an invalid one — the pivot is viable.
///      If it fails, the pivot needs reconsideration.
contract BpsSumProbe is ZamaEthereumConfig {
    /// @notice Stored encrypted shares from the most recent registration attempt.
    euint16[] private shares;

    /// @notice Encrypted sum of the most recent registration's shares.
    euint16 private runningSum;

    /// @notice Encrypted boolean: true if shares summed to 10,000.
    ebool private constraintHolds;

    /// @notice Decrypted result of the constraint check, set after off-chain reveal.
    bool public lastResult;
    bool public lastResultRevealed;

    event SharesRegistered(uint256 count);
    event ConstraintMarkedDecryptable();
    event ConstraintRevealed(bool valid);

    /// @notice Submit N encrypted bps shares, compute their encrypted sum, and store
    ///         an encrypted boolean indicating whether the sum equals 10,000.
    /// @param encShares Array of encrypted euint16 handles (basis points per stakeholder).
    /// @param inputProof Single input proof covering all handles in the batch.
    function registerShares(externalEuint16[] calldata encShares, bytes calldata inputProof) external {
        require(encShares.length >= 2, "need at least 2 shares");
        require(encShares.length <= 15, "max 15 shares per batch");

        delete shares;
        runningSum = FHE.asEuint16(0);
        FHE.allowThis(runningSum);

        for (uint256 i = 0; i < encShares.length; i++) {
            euint16 share = FHE.fromExternal(encShares[i], inputProof);
            shares.push(share);
            FHE.allowThis(share);
            runningSum = FHE.add(runningSum, share);
            FHE.allowThis(runningSum);
        }

        // Encrypted equality check: does the sum equal exactly 10,000?
        // The contract performs this comparison without ever learning the values.
        constraintHolds = FHE.eq(runningSum, uint16(10_000));
        FHE.allowThis(constraintHolds);

        lastResultRevealed = false;
        emit SharesRegistered(encShares.length);
    }

    /// @notice Mark the encrypted boolean as publicly decryptable so the off-chain
    ///         relayer + KMS can reveal it. Individual shares stay encrypted.
    function markConstraintDecryptable() external {
        FHE.makePubliclyDecryptable(constraintHolds);
        emit ConstraintMarkedDecryptable();
    }

    /// @notice Submit the off-chain decryption result + KMS proof. Verifies the
    ///         signature chain and stores the cleartext boolean. Replay-protected.
    /// @param result The cleartext boolean from off-chain publicDecrypt.
    /// @param decryptionProof KMS-signed proof that `result` is the decryption of constraintHolds.
    function finalizeConstraint(bool result, bytes calldata decryptionProof) external {
        require(!lastResultRevealed, "already revealed");

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(constraintHolds);
        FHE.checkSignatures(handles, abi.encode(result), decryptionProof);

        lastResult = result;
        lastResultRevealed = true;
        emit ConstraintRevealed(result);
    }

    /// @notice Number of shares stored from the most recent registration.
    function shareCount() external view returns (uint256) {
        return shares.length;
    }

    /// @notice Return the encrypted sum handle for inspection (cannot be decrypted by callers
    ///         without ACL grants — this only lets the frontend see the handle exists).
    function getSumHandle() external view returns (euint16) {
        return runningSum;
    }

    /// @notice Return the encrypted boolean handle (constraint result, before reveal).
    function getConstraintHandle() external view returns (ebool) {
        return constraintHolds;
    }
}
