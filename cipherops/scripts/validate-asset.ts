import { ethers } from "hardhat";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

async function main() {
  const [deployer] = await ethers.getSigners();
  const cr = await ethers.getContractAt("ConfidentialRoyalty", process.env.CR_ADDR!);
  const assetId = ethers.keccak256(ethers.toUtf8Bytes("track-001"));

  // Step 1: mark sum decryptable
  console.log("Marking sum decryptable...");
  const tx1 = await cr.markSumDecryptable(assetId);
  await tx1.wait();
  console.log("Marked.");

  // Step 2: get handle and decrypt via relayer
  const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL!,
  });

  const encSumHandle = await cr.getEncSum(assetId);
  console.log("encSum handle:", encSumHandle);

  console.log("Requesting public decryption from KMS (wait ~15s)...");
  const result = await instance.publicDecrypt([encSumHandle]);
  const decryptedSum = result.clearValues[encSumHandle];
  console.log("Decrypted sum:", decryptedSum);

  // Step 3: submit proof on-chain
  console.log("Confirming validation...");
  const tx2 = await cr.confirmValidation(
    assetId,
    decryptedSum,
    result.decryptionProof
  );
  await tx2.wait();

  const state = await cr.getAssetState(assetId);
  console.log("Final state:", state); // expect 2n (ACTIVE)
}

main().catch(console.error);
