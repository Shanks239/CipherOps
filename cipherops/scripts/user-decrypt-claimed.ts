import { ethers } from "hardhat";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

async function main() {
  const [deployer] = await ethers.getSigners();
  const cr = await ethers.getContractAt("ConfidentialRoyalty", process.env.CR_ADDR!);
  const crAddr = await cr.getAddress();
  const assetId = ethers.keccak256(ethers.toUtf8Bytes("track-001"));

  const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL!,
  });

  const rawHandle = await cr.getEncClaimed(assetId, deployer.address);
  const encClaimed = ethers.zeroPadValue(ethers.toBeHex(rawHandle), 32);

  const { publicKey, privateKey } = instance.generateKeypair();
  const startTimestamp = Math.floor(Date.now() / 1000);
  const durationDays = 1;

  const eip712 = instance.createEIP712(publicKey, [crAddr], startTimestamp, durationDays);
  const { EIP712Domain: _, ...types } = eip712.types as any;
  const sig = await deployer.signTypedData(eip712.domain, types, eip712.message);

  const result = await instance.userDecrypt(
    [{ handle: encClaimed, contractAddress: crAddr }],
    privateKey,
    publicKey,
    sig,
    [crAddr],
    deployer.address,
    startTimestamp,
    durationDays
  );

  // Print each key/value, converting BigInt to string
  for (const [k, v] of Object.entries(result)) {
    console.log(`${k}: ${v}`);
  }
  console.log("Expected: 500000 (50% of 1,000,000)");
}

main().catch(console.error);
