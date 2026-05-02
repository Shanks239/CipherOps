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
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

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
    const cleartext: boolean = result.clearValues[constraintHandle];
    const proof: string = result.decryptionProof;
    console.log("  RAW result:", JSON.stringify(result, null, 2)); console.log("  result type:", typeof result, Array.isArray(result) ? "array" : "object"); console.log("  decrypted:", cleartext);

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
    const instance = await createInstance({ ...SepoliaConfig, network: process.env.SEPOLIA_RPC_URL });

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
