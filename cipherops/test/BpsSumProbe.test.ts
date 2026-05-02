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
