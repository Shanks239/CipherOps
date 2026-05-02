# threat_model.md — RoyaltyLayer v1

## Scope

This document covers the deployed v1 system: `ConfidentialRoyalty` on Sepolia, the static frontend at `royaltylayer.zoomfrez.xyz`, and the Zama KMS/coprocessor infrastructure. It does not cover the mock token contract, which is testnet-only.

---

## Attacker 1: Malicious stakeholder

**Capability:** a legitimate rights-holder with a valid wallet and a registered split in a live asset.

**Attack vectors and mitigations:**

| Vector | Mitigation | Status |
|---|---|---|
| Read another holder's split | ACL: `FHE.allow` is per-address. The coprocessor rejects decrypt requests for handles the caller wasn't explicitly granted. | Mitigated |
| Register with invalid BPS (e.g., 9999 instead of 5000) | The KMS validates the encrypted sum. If sum ≠ 10,000, `confirmValidation` reverts and the asset stays `PENDING`. | Mitigated |
| Claim more than their share | `claimShare` computes `revenue × encSplit / 10000` entirely in FHE. The multiplier is bounded by the registered encrypted handle. No plaintext path exists. | Mitigated |
| Double-claim | `getEncClaimed` returns 0 before claim. After claim, the handle is set. The contract checks `FHE.isInitialized` before re-claim. | Mitigated |
| Grief by submitting splits that don't sum to 10,000 | Asset stays `PENDING` indefinitely. Registrant loses gas. No way to correct in v1 without redeployment. | **Known limitation** |
| Register an asset ID already in use | `getAssetState` check on registration. Frontend pre-checks and suggests a new name. | Mitigated |

---

## Attacker 2: Colluding stakeholders

**Capability:** two or more rights-holders sharing information out-of-band (e.g., revealing their own BPS values to each other), attempting to infer a third holder's split.

**Attack vectors and mitigations:**

| Vector | Mitigation | Status |
|---|---|---|
| Infer holder C's split from known values A + B and the fact that A + B + C = 10,000 | This works. If A and B share their values, they learn C = 10,000 − A − B. FHE protects on-chain privacy; it cannot prevent voluntary disclosure by participants. | **Structural limitation. Not solvable in this model.** |
| Collude with KMS to decrypt C's handle | Requires KMS to be malicious. Covered under Attacker 3. | See below |

The collusion inference attack is a fundamental property of sum-constrained secret sharing. The only mitigation is adding noise (differential privacy) or requiring a minimum number of holders such that no coalition has sufficient information. Neither is implemented in v1.

---

## Attacker 3: Malicious KMS

**Capability:** a Zama KMS node that deviates from honest behavior.

**Attack vectors and mitigations:**

| Vector | Mitigation | Status |
|---|---|---|
| Return incorrect sum during `confirmValidation` | `FHE.checkSignatures` verifies the KMS proof cryptographically. The KMS cannot fabricate a valid proof for a value it didn't compute from the actual ciphertext. | Mitigated |
| Decrypt a user's handle without authorization | ACL enforces this at the coprocessor level. The KMS and coprocessor are co-operated by Zama in v1. Single point of trust. | **Trusted party in v1** |
| Log all user-decrypt requests, correlate over time | No mitigation in v1. Threshold KMS in v2 eliminates the single-node logging capability. | **v2 scope** |
| Replay a valid decryption proof | EIP-712 signatures are time-bounded. The contract's `confirmValidation` uses a state-machine guard (`PENDING → ACTIVE`) — the same proof cannot be replayed because the asset state already changed. | Mitigated |

---

## Attacker 4: Frontend attacker

**Capability:** either a compromised CDN/hosting serving a malicious `index.html`, or an attacker who controls the network between the user and `royaltylayer.zoomfrez.xyz`.

**Attack vectors and mitigations:**

| Vector | Mitigation | Status |
|---|---|---|
| Exfiltrate plaintext BPS values before `createEncryptedInput` | If the frontend JS is replaced, plaintext values typed by the user can be exfiltrated before encryption. | **Not mitigated in v1.** Open-source code, Vercel deployment. Content hash verification not implemented. |
| Intercept and replace encrypted inputs with attacker-controlled ciphertexts | The `inputProof` binds the ciphertext to the user's address and the contract address. An attacker cannot generate a valid proof for a ciphertext they constructed. | Mitigated |
| Phishing — serve a fake UI that sends transactions to a different contract | User must verify the contract address. Frontend displays the contract address in the footer. | Partially mitigated |
| MITM on the KMS API call (user-decrypt) | TLS. Frontend communicates with Zama's relayer over HTTPS. | Mitigated |

The primary frontend risk in v1 is supply chain: a compromised Vercel deployment or CDN serving malicious JS. This is the same risk as every browser-based crypto application. The mitigation path is IPFS + ENS, or Vercel's deployment protection with signed commits.

---

## Attacker 5: Replay and signature attacks

**Capability:** any party that captures a valid signed message and attempts to reuse it.

**Attack vectors and mitigations:**

| Vector | Mitigation | Status |
|---|---|---|
| Replay `confirmValidation` proof on a different asset | The proof is cryptographically bound to the specific encrypted handle (the asset's sum ciphertext). A different asset has a different handle; the proof doesn't verify. | Mitigated |
| Replay a user-decrypt EIP-712 signature | Signatures include a timestamp and duration. The Zama SDK rejects requests outside the valid window. | Mitigated |
| Replay the same `confirmValidation` proof on the same asset | State-machine guard: once an asset transitions to `ACTIVE`, the `markSumDecryptable` + `confirmValidation` sequence cannot be re-entered. | Mitigated |
| Front-run `registerAsset` to claim an asset ID | Asset IDs are deterministic `keccak256` of the asset name. A front-runner claiming the ID before the real registrant would waste their gas and the name would be taken. The real registrant sees the collision and uses a different name. The front-runner gains nothing — they don't have the correct splits. | Mitigated (griefing possible, not exploitable) |
| Signature malleability | ethers v6 uses canonical ECDSA signatures. Non-issue on EVM. | Mitigated |

---

## Summary risk matrix

| Threat | Severity | Mitigated in v1 |
|---|---|---|
| Stakeholder reads another's split | High | Yes |
| Double-claim | High | Yes |
| Invalid sum accepted | High | Yes |
| KMS logs user-decrypt requests | Medium | No — honest-but-curious assumption |
| Collusion inference (N-1 parties) | Medium | No — structural |
| Frontend supply chain | Medium | Partial |
| Griefing via invalid registration | Low | No — known limitation |
| Phishing | Low | Partial |

---

## Out of scope (v1)

- MEV / transaction reordering attacks (standard Ethereum risk, not specific to this protocol)
- Side-channel attacks on the KMS hardware
- Sybil attacks on stakeholder registration (no identity binding in v1)
- Economic attacks on the mock token (testnet only)
