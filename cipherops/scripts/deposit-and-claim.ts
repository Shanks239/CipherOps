import { ethers } from "hardhat";
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

async function main() {
  const [deployer] = await ethers.getSigners();
  const cr = await ethers.getContractAt("ConfidentialRoyalty", process.env.CR_ADDR!);
  const token = await ethers.getContractAt("MockConfidentialToken", process.env.TOKEN_ADDR!);
  const crAddr = await cr.getAddress();
  const assetId = ethers.keccak256(ethers.toUtf8Bytes("track-001"));

  const instance = await createInstance({
    ...SepoliaConfig,
    network: process.env.SEPOLIA_RPC_URL!,
  });

  // Step 1: mint tokens to CR contract (pre-fund for claim payouts)
  console.log("Minting revenue to contract...");
  const mintTx = await token.mintPlaintext(crAddr, 1000000n);
  await mintTx.wait();
  console.log("Minted 1,000,000 units to CR contract.");

  // Step 2: deposit encrypted revenue against the asset
  console.log("Depositing revenue...");
  const input = instance.createEncryptedInput(crAddr, deployer.address);
  input.add128(1000000n);
  const enc = await input.encrypt();

  const depTx = await cr.depositRevenue(assetId, enc.handles[0], enc.inputProof);
  await depTx.wait();
  console.log("Revenue deposited.");

  // Step 3: claim deployer's share (5000 bps = 50%)
  console.log("Claiming share...");
  const claimTx = await cr.claimShare(assetId);
  const claimReceipt = await claimTx.wait();
  console.log("Claim gas used:", claimReceipt!.gasUsed.toString());

  // Step 4: read encrypted claimed amount
  const encClaimed = await cr.getEncClaimed(assetId, deployer.address);
  console.log("encClaimed handle:", encClaimed);

  // Step 5: user-decrypt to verify correctness
  const { publicKey, privateKey } = instance.generateKeypair();
  const eip712 = instance.createEIP712(publicKey, crAddr);
  const sig = await deployer.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
  );
  const claimed = await instance.userDecrypt(
    encClaimed,
    privateKey,
    publicKey,
    sig,
    crAddr,
    deployer.address
  );
  console.log("Decrypted claimed amount:", claimed);
  console.log("Expected: 500000 (50% of 1,000,000)");
}

main().catch(console.error);
