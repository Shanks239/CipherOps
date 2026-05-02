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
