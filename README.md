# CipherOps Sentinel

**Private on-chain payroll infrastructure built on Zama's FHEVM.**

Managers can authorize payroll execution while amounts remain encrypted. Employees can decrypt only ciphertexts explicitly granted to them. Admins can optionally reveal aggregate totals through a verified decryption flow. No salary data is ever readable in plaintext by validators, indexers, or other employees.

**Deployed on Sepolia:** `0x84C05228D3c79Ae4D7BC9a7C43061ffb37C75C63`

---

## The Problem

Web3 payroll is broken by default. Every `uint256` salary stored on a public chain is readable by any indexer, block explorer, or competitor running an archive node. Access control modifiers gate who can call a function; they don't hide the underlying state. The data is on the ledger. Anyone can read it.

Traditional approaches work around this with off-chain infrastructure or centralized databases, which defeats the point of on-chain operations entirely.

FHE solves the actual problem. Contracts store encrypted values and compute on them directly; plaintext never appears on-chain at any stage. Zama's FHEVM brings this to the EVM: salary arithmetic runs on encrypted handles, the coprocessor evaluates operations off-chain, and the chain records only ciphertexts. Decryption requires both ACL permission and a KMS signature; neither is obtainable without explicit authorization.

---

## Current Status

- Confidential Payroll Engine deployed on Sepolia
- 10/10 tests passing on Hardhat mock environment
- Source verification pending (restricted network environment during build)
- Frontend: in progress
- Expansion modules: planned

---

## What's Built

The deployed core is a single-contract payroll engine with three roles and three encrypted state variables.

```
Admin       — deploys, manages roles, triggers public payroll reports
Manager     — adds employees, sets encrypted salaries, approves payment runs
Employee    — decrypts their own salary and pending payment
```

```solidity
mapping(address => euint64) private salaries;
mapping(address => euint64) private pendingPayments;
euint64 private totalPayrollCommitted;
```

All three are `euint64` ciphertext handles. No function in the contract returns plaintext salary data.

---

## User Flow

1. Manager encrypts a salary value on the frontend using the relayer SDK
2. Manager calls `setSalary` with the encrypted input and ZK proof
3. Contract stores the ciphertext; ACL grants the employee read permission
4. Manager calls `approvePayment` after the pay interval elapses
5. Employee calls `userDecrypt` with an EIP712 signature to read their own pending amount
6. Admin can optionally call `revealPayrollTotal` to trigger a verified public decryption of the aggregate

---

## Key Functions

**`setSalary(address, externalEuint64, bytes proof)`**
Sets an employee's encrypted salary. Input proof verifies the caller knows the plaintext. ACL grants compute access to the contract, read access to the employee, and read access to the calling manager.

**`approvePayment(address employee)`**
Moves the current salary into `pendingPayments` if the pay interval has elapsed. Overflow handled with `FHE.select`; a revert would leak information through gas differences, so conditional logic stays encrypted throughout.

**`approveAllEligiblePayments()`**
Batch approval across all eligible employees. Same overflow guards per iteration. Gas-heavy at scale; intended for small teams in this release.

**`revealPayrollTotal()`**
Marks `totalPayrollCommitted` as publicly decryptable. Off-chain: call `publicDecrypt([handle])`. On-chain: submit KMS-signed result via `finalizePayrollReport`. Replay-protected via proof hash mapping.

**`getEncryptedSalary(address employee)`**
Returns the ciphertext handle. Readable only by the employee or a manager with ACL permission. The handle reveals nothing without a decryption key.

---

## Access Control

Role checks and ACL are separate enforcement layers; both are required.

Role checks (`onlyRole`) control who can call a function. ACL (`FHE.allow`) controls who can decrypt the resulting ciphertext. Passing a role check doesn't grant decryption access; ACL grants don't bypass role checks.

```solidity
FHE.allowThis(salaries[employee]);         // contract retains compute access
FHE.allow(salaries[employee], employee);   // employee can userDecrypt their own
FHE.allow(salaries[employee], msg.sender); // calling manager retains read access
```

Managers can be granted access to specific employees' ciphertexts via `grantSalaryReadAccess`. Access is additive and permanent unless the contract is redeployed.

---

## Threat Model

**Protected against:**
- Public blockchain observers reading salary state
- Indexers and analytics platforms scraping payroll data
- Employees viewing each other's salaries
- Managers who were not explicitly granted ACL read access
- Competitors scraping salary data to identify and poach employees

**Not protected against:**
- Compromised employee wallets or private keys
- Malicious admins who have been granted decrypt authority
- Off-chain metadata leakage (e.g. inferred from transaction timing or gas costs)
- Endpoint or device compromise on the decrypting party's side

---

## Market Relevance

Payroll data is among the most sensitive information an organization holds. In traditional Web3 contexts, putting payroll on-chain means every salary is public record. That's a non-starter for real adoption.

CipherOps demonstrates a path where organizations get the auditability and settlement guarantees of on-chain operations without exposing compensation data. The selective audit feature (`grantSalaryReadAccess`) lets compliance or legal teams access specific records without broadcasting amounts globally. Aggregate totals can be revealed on-demand through the verified decryption flow, satisfying reporting requirements without publishing individual salaries.

The same pattern applies anywhere sensitive financial data needs on-chain processing: insurance claims, contractor payments, grant disbursements, DAO compensation.

---

## Limitations and Known Constraints

- Testnet deployment only; mainnet requires Zama relayer API key and additional gas budget
- Hardhat 2.22.0 pinned; `@fhevm/hardhat-plugin` is incompatible with Hardhat 3
- FHE operations are 10-1000x more gas-intensive than equivalent plaintext EVM ops; `approveAllEligiblePayments` is not viable for large employee sets in this release
- `FHE.div` operations cost 700k-1.2M gas; avoided in hot paths
- Frontend decrypt UX requires EIP712 signing flow; not yet implemented in this release
- Source verification blocked by `solc-bin.ethereum.org` being unreachable in restricted network environments; standard JSON input generated and available in repo

---

## Proof and Evidence

**Deployment:**
`https://sepolia.etherscan.io/address/0x84C05228D3c79Ae4D7BC9a7C43061ffb37C75C63`

**Test suite output:**
```
ConfidentialPayroll
  ✔ deployer is admin
  ✔ admin can grant manager role
  ✔ non-admin cannot grant roles
  ✔ manager can add employee
  ✔ cannot add same employee twice
  ✔ stranger cannot add employee
  ✔ manager can set encrypted salary (84ms)
  ✔ employee salary handle is set and accessible
  ✔ stranger cannot read salary (58ms)
  ✔ cannot approve payment before interval elapses (68ms)

10 passing (813ms)
```

**Source verification:** Standard JSON input generated from build artifacts, available at `cipherops/standard-input.json`. Etherscan verification pending from an unrestricted network environment.

---

## Deployment

**Network:** Ethereum Sepolia
**Address:** `0x84C05228D3c79Ae4D7BC9a7C43061ffb37C75C63`
**Compiler:** Solidity 0.8.24, EVM target: paris
**FHEVM:** @fhevm/solidity via ZamaEthereumConfig

---

## Run Locally

```bash
git clone https://github.com/Shanks239/CipherOps
cd CipherOps/cipherops
npm install --legacy-peer-deps
npx hardhat compile
npx hardhat test
```

Sepolia deployment:

```bash
export SEPOLIA_RPC_URL="your_rpc_url"
export PRIVATE_KEY="your_wallet_key"
npx hardhat run scripts/deploy.ts --network sepolia
```

---

## Stack

| Component | Version |
|---|---|
| Solidity | 0.8.24 |
| @fhevm/solidity | 0.11.x |
| Hardhat | 2.22.0 |
| @fhevm/hardhat-plugin | 0.4.2 |
| @zama-fhe/relayer-sdk | 0.4.1 |
| ethers | 6.13.0 |

---

## Architecture

The deployed Confidential Payroll Engine is the live production proof-of-concept for a broader system. Expansion modules are planned but not deployed.

```
CipherOps Sentinel
├── Confidential Payroll Engine    ← live on Sepolia
├── Encrypted Reserve Vault        ← planned
├── Ops Vault with Policy Engine   ← in design
└── AI Governed Risk Layer         ← future work
```

The Reserve and Ops vaults follow the same ACL and encrypted state patterns as the payroll engine. The AI risk layer is designed as a governed operator: bounded by on-chain policy limits, subject to manager override, with all triggered actions requiring encrypted amount verification before execution.

---

## Why FHE

Blockchains are public. Every state variable is readable by anyone running a node; access control modifiers don't change that. A salary stored as `uint256` is visible regardless of which functions restrict writes to it.

FHE solves a different problem: computation directly on encrypted data, producing correct results without ever exposing plaintext. Zama's FHEVM implements this on the EVM using TFHE, a scheme that performs bootstrapping per gate operation rather than deferring it. The result preserves normal smart-contract execution guarantees while adding confidentiality over values.

---

## Bounty Track

The SKILL.md submitted separately to the Zama Bounty Track documents the full FHEVM development workflow: encrypted types, operations, access control, input proofs, decryption flows, frontend integration, testing, 14 anti-patterns, and 15 real toolchain errors with resolutions encountered during this build.

---

## License

BSD-3-Clause-Clear
