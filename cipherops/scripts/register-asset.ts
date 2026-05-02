import { ethers } from "hardhat";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

async function main() {
  const [deployer] = await ethers.getSigners();
  const cr = await ethers.getContractAt("ConfidentialRoyalty", process.env.CR_ADDR!);
  const crAddr = await cr.getAddress();

  const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL!,
  });

  const assetId = ethers.keccak256(ethers.toUtf8Bytes("track-001"));

  // Two stakeholders: deployer + a second known address
  // In demo these are the "two rights-holders"
  const alice = deployer.address;
  const bob = "0x000000000000000000000000000000000000dead"; // placeholder for demo

  const stakeholders = [alice, bob];

  const input = instance.createEncryptedInput(crAddr, deployer.address);
  input.add16(5000);
  input.add16(5000);
  const enc = await input.encrypt();

  console.log("Registering asset...");
  const tx = await cr.registerAsset(
    assetId,
    stakeholders,
    [enc.handles[0], enc.handles[1]],
    enc.inputProof
  );
  const receipt = await tx.wait();
  console.log("Gas used:", receipt!.gasUsed.toString());
  console.log("AssetId:", assetId);
  console.log("State:", await cr.getAssetState(assetId));
}

main().catch(console.error);
