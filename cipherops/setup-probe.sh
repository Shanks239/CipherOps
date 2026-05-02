#!/usr/bin/env bash
# setup-probe.sh — creates the four BpsSumProbe files inside an existing CipherOps project.
# Run this from your CipherOps project root (the directory containing hardhat.config.ts).
#
# Usage:
#   bash setup-probe.sh
#
# This script is idempotent — running it twice overwrites the four files cleanly.
# It does NOT touch any other file in your project.

set -euo pipefail

# Sanity check — refuse to run outside a Hardhat project so we don't pollute random dirs.
if [ ! -f hardhat.config.ts ] && [ ! -f hardhat.config.js ]; then
  echo "ERROR: no hardhat.config found in $(pwd)"
  echo "cd into your CipherOps project root and re-run."
  exit 1
fi

mkdir -p contracts test scripts

# ─────────────────────────────────────────────────────────────────────────────
cat > contracts/BpsSumProbe.sol << 'CONTRACT_EOF'
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
CONTRACT_EOF

# ─────────────────────────────────────────────────────────────────────────────
cat > test/BpsSumProbe.test.ts << 'TEST_EOF'
import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import type { BpsSumProbe } from "../typechain-types";

/**
 * Probe test for ConfidentialRoyalty viability.
 *
 * What we're verifying:
 *   1. Encrypted euint16 inputs can be summed and compared to a plaintext constant.
 *   2. The resulting ebool can be marked publicly decryptable.
 *   3. In the Hardhat mock, we can confirm the boolean handle exists and is non-zero.
 *
 * What we're NOT verifying here (requires Sepolia for the full loop):
 *   - End-to-end relayer + KMS decryption of the boolean.
 *   - Production gas behavior under real coprocessor pricing.
 *
 * If these mock tests pass, the next step is the same flow on Sepolia.
 */
describe("BpsSumProbe — viability test for ConfidentialRoyalty", () => {
    let probe: BpsSumProbe;
    let registrant: any;

    beforeEach(async () => {
        [registrant] = await ethers.getSigners();
        const Factory = await ethers.getContractFactory("BpsSumProbe");
        probe = (await Factory.deploy()) as unknown as BpsSumProbe;
        await probe.waitForDeployment();
    });

    /**
     * Helper: encrypt an array of basis-point values into a single batched input proof.
     * Handle order in the returned array matches the order values were added.
     */
    async function encryptShares(values: number[]) {
        const input = fhevm.createEncryptedInput(
            await probe.getAddress(),
            registrant.address
        );
        for (const v of values) {
            input.add16(v);
        }
        return input.encrypt();
    }

    it("accepts a valid split (5 shares summing to 10,000)", async () => {
        // 30% / 25% / 20% / 15% / 10% = 100%
        const shares = [3000, 2500, 2000, 1500, 1000];
        const enc = await encryptShares(shares);

        const tx = await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);
        const receipt = await tx.wait();
        expect(receipt?.status).to.equal(1);

        expect(await probe.shareCount()).to.equal(5n);

        const sumHandle = await probe.getSumHandle();
        expect(sumHandle).to.not.equal(ethers.ZeroHash);

        const constraintHandle = await probe.getConstraintHandle();
        expect(constraintHandle).to.not.equal(ethers.ZeroHash);
    });

    it("accepts an invalid split without reverting (constraint check returns encrypted false)", async () => {
        // Sums to 9,500 — invalid, but the contract should NOT revert on registration.
        // The whole point is that the contract cannot tell whether the constraint
        // holds at registration time. It only knows after the boolean is decrypted.
        const shares = [3000, 2500, 2000, 1500, 500];
        const enc = await encryptShares(shares);

        const tx = await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);
        const receipt = await tx.wait();
        expect(receipt?.status).to.equal(1);

        const constraintHandle = await probe.getConstraintHandle();
        expect(constraintHandle).to.not.equal(ethers.ZeroHash);
        // We cannot assert the cleartext value in mock — we verify it on Sepolia.
    });

    it("supports edge case: 2 shares (50/50 split)", async () => {
        const shares = [5000, 5000];
        const enc = await encryptShares(shares);
        const tx = await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);
        expect((await tx.wait())?.status).to.equal(1);
    });

    it("supports edge case: 15 shares (max batch)", async () => {
        // 14 × 666 + 716 = 9324 + 716 = 10,040. Slightly off — fine for this test.
        // We're just confirming the loop and gas tolerate 15 entries.
        const shares = new Array(14).fill(666);
        shares.push(716);
        const enc = await encryptShares(shares);
        const tx = await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);
        expect((await tx.wait())?.status).to.equal(1);
    });

    it("rejects fewer than 2 shares", async () => {
        const enc = await encryptShares([10000]);
        await expect(
            probe.connect(registrant).registerShares(enc.handles, enc.inputProof)
        ).to.be.reverted;
    });

    it("rejects more than 15 shares", async () => {
        const shares = new Array(16).fill(625);
        const enc = await encryptShares(shares);
        await expect(
            probe.connect(registrant).registerShares(enc.handles, enc.inputProof)
        ).to.be.reverted;
    });

    it("can mark the constraint boolean publicly decryptable", async () => {
        const shares = [4000, 3000, 2000, 1000];
        const enc = await encryptShares(shares);
        await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);

        const tx = await probe.connect(registrant).markConstraintDecryptable();
        expect((await tx.wait())?.status).to.equal(1);
    });

    /**
     * Gas measurement — informational, not a pass/fail.
     * If 5-share registration > 2M gas, the production design needs to chunk or
     * refactor (e.g., incremental sum across multiple txs).
     */
    it("[gas] reports gas usage for typical splits", async () => {
        const cases = [
            { name: "2 shares",  shares: [5000, 5000] },
            { name: "5 shares",  shares: [3000, 2500, 2000, 1500, 1000] },
            { name: "10 shares", shares: [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000] },
            { name: "15 shares", shares: new Array(15).fill(666) },
        ];
        for (const c of cases) {
            const enc = await encryptShares(c.shares);
            const tx = await probe.connect(registrant).registerShares(enc.handles, enc.inputProof);
            const r = await tx.wait();
            console.log(`    ${c.name}: ${r?.gasUsed?.toString()} gas`);
        }
    });
});
TEST_EOF

# ─────────────────────────────────────────────────────────────────────────────
cat > scripts/probe-deploy.ts << 'DEPLOY_EOF'
import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");

    const Factory = await ethers.getContractFactory("BpsSumProbe");
    const probe = await Factory.deploy();
    await probe.waitForDeployment();

    const addr = await probe.getAddress();
    console.log("BpsSumProbe deployed to:", addr);
    console.log("");
    console.log("Next: export PROBE_ADDR=" + addr);
    console.log("Then: npx hardhat run scripts/probe-reveal.ts --network sepolia");
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
DEPLOY_EOF

# ─────────────────────────────────────────────────────────────────────────────
cat > scripts/probe-reveal.ts << 'REVEAL_EOF'
/**
 * Sepolia reveal script — the full viability test.
 *
 * Runs ONLY against Sepolia (real coprocessor + real KMS).
 * Performs the complete loop:
 *   1. Register a known-valid 5-share split (encrypted)
 *   2. Register a known-invalid split (encrypted)
 *   3. Mark each constraint boolean publicly decryptable
 *   4. Off-chain decrypt via the relayer
 *   5. Submit the proof on-chain via finalizeConstraint
 *   6. Read lastResult and confirm it matches expected
 *
 * Pass criteria:
 *   - Valid split → lastResult == true
 *   - Invalid split → lastResult == false
 *
 * Set PROBE_ADDR before running:
 *   export PROBE_ADDR=0x...
 */

import { ethers } from "hardhat";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk";

const PROBE_ADDR = process.env.PROBE_ADDR;
if (!PROBE_ADDR) {
    throw new Error("Set PROBE_ADDR to the deployed BpsSumProbe address");
}

async function registerAndReveal(
    probe: any,
    instance: any,
    signer: any,
    label: string,
    shares: number[],
    expected: boolean
) {
    console.log(`\n=== ${label}: shares=[${shares.join(",")}], expected=${expected} ===`);

    // 1. Encrypt and register
    const input = instance.createEncryptedInput(await probe.getAddress(), signer.address);
    for (const s of shares) input.add16(s);
    const enc = await input.encrypt();

    console.log("Registering encrypted shares...");
    let tx = await probe.connect(signer).registerShares(enc.handles, enc.inputProof);
    await tx.wait();
    console.log("  registered. tx:", tx.hash);

    // 2. Mark publicly decryptable
    console.log("Marking constraint boolean publicly decryptable...");
    tx = await probe.connect(signer).markConstraintDecryptable();
    await tx.wait();
    console.log("  marked. tx:", tx.hash);

    // 3. Off-chain decrypt
    const constraintHandle = await probe.getConstraintHandle();
    console.log("Constraint handle:", constraintHandle);

    console.log("Awaiting public decryption from KMS (typically 5-30s on Sepolia)...");
    const result = await instance.publicDecrypt([constraintHandle]);
    const cleartext: boolean = result[constraintHandle];
    const proof: string = result[`${constraintHandle}_proof`] || result.proof;
    console.log("  decrypted:", cleartext);

    // 4. Submit proof on-chain
    console.log("Finalizing on-chain...");
    tx = await probe.connect(signer).finalizeConstraint(cleartext, proof);
    await tx.wait();

    // 5. Verify
    const lastResult = await probe.lastResult();
    const revealed = await probe.lastResultRevealed();
    console.log(`  lastResult=${lastResult}, revealed=${revealed}`);

    const pass = lastResult === expected && revealed === true;
    console.log(`  ${pass ? "PASS" : "FAIL"}`);
    return pass;
}

async function main() {
    const [signer] = await ethers.getSigners();
    console.log("Signer:", signer.address);

    const probe = await ethers.getContractAt("BpsSumProbe", PROBE_ADDR!);
    const instance = await createInstance(SepoliaConfig);

    const results: { label: string; pass: boolean }[] = [];

    results.push({
        label: "valid: 30/25/20/15/10",
        pass: await registerAndReveal(
            probe, instance, signer,
            "valid: 30/25/20/15/10",
            [3000, 2500, 2000, 1500, 1000],
            true
        ),
    });

    results.push({
        label: "invalid: sum=9500",
        pass: await registerAndReveal(
            probe, instance, signer,
            "invalid: sum=9500",
            [3000, 2500, 2000, 1500, 500],
            false
        ),
    });

    console.log("\n========== SUMMARY ==========");
    for (const r of results) {
        console.log(`  ${r.pass ? "PASS" : "FAIL"}  ${r.label}`);
    }
    const allPass = results.every(r => r.pass);
    console.log(`\nViability: ${allPass ? "CONFIRMED - proceed with pivot" : "NOT CONFIRMED - debug or reconsider"}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
REVEAL_EOF

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Created files:"
ls -la contracts/BpsSumProbe.sol test/BpsSumProbe.test.ts scripts/probe-deploy.ts scripts/probe-reveal.ts
echo ""
echo "Next steps:"
echo "  1. npx hardhat compile"
echo "  2. npx hardhat test test/BpsSumProbe.test.ts"
echo "  3. (if mock tests pass) npx hardhat run scripts/probe-deploy.ts --network sepolia"
echo "  4. export PROBE_ADDR=<address from step 3>"
echo "  5. npx hardhat run scripts/probe-reveal.ts --network sepolia"

