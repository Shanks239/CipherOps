# trust_model.md — RoyaltyLayer v1

## What this document is

A precise account of who or what RoyaltyLayer trusts, what that trust grants them, and where the guarantees stop. Read this before making claims about privacy.

---

## Parties

| Party | Role |
|---|---|
| Rights-holder | Registers splits, claims share, optionally grants observer access |
| Distributor | Deposits revenue into an active asset |
| Observer | Read-only access to one stakeholder's encrypted share, granted explicitly |
| Zama KMS | Decrypts encrypted handles when authorized by the contract |
| FHEVM coprocessor | Executes FHE operations; stores ciphertexts off-chain |
| Ethereum validators | Order and finalize transactions |
| Frontend | Encrypts inputs locally; submits transactions; handles user decryption |

---

## Trust assumptions — v1

### Zama KMS (Option A: honest-but-curious)

v1 operates under an honest-but-curious KMS assumption.

**What the KMS can do:**
- See which handles it is asked to decrypt
- See the plaintext of handles marked `makePubliclyDecryptable` (the encrypted sum during validation)
- See user-decrypt requests (handle + requesting address)

**What the KMS cannot do, given honest behavior:**
- Return incorrect decryption results
- Decrypt handles not explicitly authorized by the contract ACL
- Link a user-decrypt request to the underlying split value without already knowing the split

**What the KMS can do if malicious:**
- Collude with a stakeholder to decrypt their handle at an unauthorized time
- Log all decryption requests and attempt correlation attacks over time
- Return a crafted plaintext during `confirmValidation`, causing an asset to activate with an incorrect sum

This is the central trust assumption of v1. It is not eliminated. It is bounded.

**Mitigation in place:** the contract uses `FHE.checkSignatures` to verify the KMS proof before accepting the decrypted sum. The KMS cannot return an arbitrary plaintext without producing a valid cryptographic proof, which requires performing the actual decryption.

**Mitigation deferred to v2:** threshold KMS (t-of-n). No single KMS node decrypts independently. Requires Zama infrastructure support not yet available on Sepolia.

---

### FHEVM coprocessor

Stores ciphertexts and executes FHE operations. Operated by Zama.

**Trust assumption:** honest execution. If the coprocessor returns incorrect FHE operation results, on-chain state corrupts in ways the contract cannot detect.

**Mitigation:** coprocessor operations are deterministic and verifiable in principle. v1 trusts Zama's coprocessor integrity at the same level as trusting an EVM client implementation.

---

### Rights-holders

**Mutual distrust assumption:** rights-holders do not trust each other. This is the core motivation for FHE. Each stakeholder encrypts their own split before submission. No stakeholder can read another's plaintext.

**What a rights-holder can do:**
- Submit any BPS value
- Attempt duplicate asset ID registration (prevented by state check)
- Call `claimShare` multiple times (prevented — handle reads 0 post-claim)

**What a rights-holder cannot do:**
- Read another holder's encrypted split (ACL blocks this)
- Bypass sum validation (contract gates `PENDING → ACTIVE` on KMS proof)
- Claim more than their proportional share (FHE multiplication bounds this)

---

### Frontend

Runs in the user's browser. Not trusted by the contract.

**Trust property:** the contract validates the ZK proof of knowledge (`inputProof`) bundled with every encrypted input. A malicious frontend cannot submit a fake ciphertext. It can submit a valid ciphertext for the wrong value — but that only harms the submitting user.

**Frontend cannot:**
- Forge another user's EIP-712 signature
- Bypass ACL to read another user's handle
- Submit an encrypted value that passes the KMS sum check unless the values are actually correct

**Residual risk:** a compromised frontend (supply chain attack) could exfiltrate plaintext BPS values before encryption. Mitigation: open-source frontend, content hash verification. Not implemented in v1.

---

### Ethereum validators

Standard Ethereum trust model. Validators see transaction calldata — which contains encrypted handles, not plaintext splits. They cannot read underlying values.

Validators can reorder or censor transactions and see which addresses interact with which asset IDs. They cannot read encrypted split values or forge KMS decryption proofs.

---

## Auditability (Option A implementation)

Since v1 uses an honest-but-curious KMS rather than threshold decryption, auditability is the primary mitigation against KMS misbehavior.

**Decryption log:** every `confirmValidation` call emits the asset ID, the decrypted sum, and the transaction hash on-chain. Anyone can verify on Etherscan that the accepted sum equals 10,000 bps. If the KMS returned an incorrect value, the mismatch is publicly visible.

**Request provenance:** each user-decrypt request is signed with an EIP-712 message binding the requesting address, the contract address, and a timestamp window. The KMS cannot respond to a request outside the signed window. Replaying an old signature fails at the SDK level.

**What this does not prove:** the KMS didn't log plaintext splits during user-decrypt. That requires threshold decryption.

---

## What RoyaltyLayer does NOT claim

- Splits are provably hidden from Zama
- The frontend is tamper-proof
- Splits can be updated after registration
- Observer grants can be revoked

These are documented limitations, not oversights.

---

## v2 upgrade path

| Limitation | v2 solution |
|---|---|
| Single KMS node | Threshold KMS: t-of-n, no single point of compromise |
| Immutable splits | Epoch-based re-encryption with version accounting |
| Irrevocable observer grants | Epoch key rotation excludes revoked observers |
| Frontend trust | IPFS hosting + content hash pinning |
