import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // Deploy mock token first
  const Mock = await ethers.getContractFactory("MockConfidentialToken");
  const token = await Mock.deploy();
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();
  console.log("MockConfidentialToken:", tokenAddr);

  // Deploy main contract
  const CR = await ethers.getContractFactory("ConfidentialRoyalty");
  const cr = await CR.deploy(tokenAddr);
  await cr.waitForDeployment();
  const crAddr = await cr.getAddress();
  console.log("ConfidentialRoyalty:", crAddr);

  console.log("\nSet these in your env:");
  console.log(`TOKEN_ADDR=${tokenAddr}`);
  console.log(`CR_ADDR=${crAddr}`);
}

main().catch(console.error);
