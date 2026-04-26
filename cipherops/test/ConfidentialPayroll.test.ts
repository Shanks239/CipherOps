import { expect } from "chai";
import { ethers } from "hardhat";
import { fhevm } from "hardhat";

describe("ConfidentialPayroll", function () {
  let contract: any;
  let admin: any;
  let manager: any;
  let employee: any;
  let stranger: any;

  beforeEach(async function () {
    [admin, manager, employee, stranger] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("ConfidentialPayroll");
    contract = await Factory.deploy();
    await contract.waitForDeployment();
    await (await contract.connect(admin).grantRole(manager.address, 2n)).wait();
  });

  it("deployer is admin", async function () {
    expect(await contract.roles(admin.address)).to.equal(3n);
  });

  it("admin can grant manager role", async function () {
    expect(await contract.roles(manager.address)).to.equal(2n);
  });

  it("non-admin cannot grant roles", async function () {
    await expect(
      contract.connect(stranger).grantRole(stranger.address, 2n)
    ).to.be.revertedWith("CPE: admin only");
  });

  it("manager can add employee", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    expect(await contract.roles(employee.address)).to.equal(1n);
  });

  it("cannot add same employee twice", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    await expect(
      contract.connect(manager).addEmployee(employee.address)
    ).to.be.revertedWith("CPE: already employee");
  });

  it("stranger cannot add employee", async function () {
    await expect(
      contract.connect(stranger).addEmployee(employee.address)
    ).to.be.revertedWith("CPE: insufficient role");
  });

  it("manager can set encrypted salary", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    const contractAddress = await contract.getAddress();
    const input = fhevm.createEncryptedInput(contractAddress, manager.address);
    input.add64(5000n);
    const encrypted = await input.encrypt();
    await (await contract.connect(manager).setSalary(
      employee.address, encrypted.handles[0], encrypted.inputProof
    )).wait();
    const schedule = await contract.connect(manager).getSchedule(employee.address);
    expect(schedule.active).to.equal(true);
  });

  it("employee salary handle is set and accessible", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    const contractAddress = await contract.getAddress();
    const input = fhevm.createEncryptedInput(contractAddress, manager.address);
    input.add64(7500n);
    const encrypted = await input.encrypt();
    await (await contract.connect(manager).setSalary(
      employee.address, encrypted.handles[0], encrypted.inputProof
    )).wait();

    const handle = await contract.connect(employee).getEncryptedSalary(employee.address);
    // Handle is a non-zero bytes32 — confirms salary was set and ACL allows employee read
    expect(handle).to.not.equal(ethers.ZeroHash);
  });

  it("stranger cannot read salary", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    await expect(
      contract.connect(stranger).getEncryptedSalary(employee.address)
    ).to.be.revertedWith("CPE: not authorized");
  });

  it("cannot approve payment before interval elapses", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    const contractAddress = await contract.getAddress();
    const input = fhevm.createEncryptedInput(contractAddress, manager.address);
    input.add64(5000n);
    const encrypted = await input.encrypt();
    await (await contract.connect(manager).setSalary(
      employee.address, encrypted.handles[0], encrypted.inputProof
    )).wait();
    await expect(
      contract.connect(manager).approvePayment(employee.address)
    ).to.be.revertedWith("CPE: payment interval not elapsed");
  });

  it("pending payment handle is set after approval", async function () {
    await (await contract.connect(manager).addEmployee(employee.address)).wait();
    const contractAddress = await contract.getAddress();
    const input = fhevm.createEncryptedInput(contractAddress, manager.address);
    input.add64(3000n);
    const encrypted = await input.encrypt();
    await (await contract.connect(manager).setSalary(
      employee.address, encrypted.handles[0], encrypted.inputProof
    )).wait();

    await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine", []);
    await (await contract.connect(manager).approvePayment(employee.address)).wait();

    const handle = await contract.connect(employee).getEncryptedPendingPayment(employee.address);
    expect(handle).to.not.equal(ethers.ZeroHash);
  });
});
