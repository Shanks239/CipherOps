import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const Factory = await ethers.getContractFactory("ConfidentialPayroll");
  const contract = await Factory.deploy();
  await contract.waitForDeployment();

  console.log("ConfidentialPayroll deployed to:", await contract.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
