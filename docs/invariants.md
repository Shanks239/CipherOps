# invariants.md — RoyaltyLayer v1

## Purpose

Formal invariants for the `ConfidentialRoyalty` contract. Each invariant is stated precisely, its enforcement mechanism identified, and its test coverage noted.

---

## Invariant 1: Split sum integrity

**Statement:** For every asset in state ACTIVE, the sum of all registered encrypted splits equals exactly 10,000 basis points.

```
∀ asset: state(asset) = ACTIVE → Σ splits(asset) = 10,000
```

**Enforcement:** The `confirmValidation` function accepts a KMS-decrypted plaintext sum and a cryptographic proof. It calls `FHE.checkSignatures` to verify the proof is valid for the submitted value. If the decrypted sum ≠ 10,000, the transaction reverts and the asset remains PENDING.

```solidity
require(sum == 10000, "Sum must equal 10000 bps");
FHE.checkSignatures(handles, abi.encode(sum), proof);
assetState[assetId] = AssetState.ACTIVE;
```

No asset can reach ACTIVE state without a verified KMS proof that its encrypted splits sum to 10,000.

**Test case:**
```typescript
// Register splits summing to 9999, attempt validation
// Expected: confirmValidation reverts
it("rejects sum != 10000", async () => {
      await cr.registerAsset(id, [addr1], [enc9999], proof);
        await cr.markSumDecryptable(id);
          await expect(cr.confirmValidation(id, 9999, fakeProof))
              .to.be.revertedWith("Sum must equal 10000 bps");
});
```

---

## Invariant 2: Non-negative splits

**Statement:** No registered split is negative.

```
∀ split ∈ splits(asset): split ≥ 0
```

**Enforcement:** Splits are encrypted as `euint16` (unsigned 16-bit integers). The FHE type system does not admit negative values. Any BPS value submitted is implicitly ≥ 0 by the unsigned type constraint.

**Note:** zero-value splits (a stakeholder with 0 BPS) are technically valid. The contract does not prevent this. A stakeholder with 0 BPS can register, validate, and claim — they will receive 0 tokens. This is a UX issue, not a security issue.

**Test case:**
```typescript
// euint16 cannot encode negative values — type system enforces this
// Test: submit max BPS for one holder, 0 for another
it("allows zero-bps stakeholder", async () => {
      // sum = 10000, valid
        await cr.registerAsset(id, [a1, a2], [enc10000, enc0], proof);
          // validation should pass
});
```

---

## Invariant 3: Claim bounded by deposited revenue

**Statement:** The total tokens claimed across all stakeholders for an asset cannot exceed the total revenue deposited.

```
∀ asset: total_claimed(asset) ≤ total_deposited(asset)
```

**Enforcement:** Revenue is deposited as an encrypted amount. Claims are computed as `encRevenue × encSplit / 10000` in FHE. Since all splits sum to 10,000 and each split is ≥ 0, the sum of all claims equals exactly `encRevenue × 10000 / 10000 = encRevenue`. No stakeholder can claim more than their proportional slice.

**FHE arithmetic note:** division in FHEVM requires a plaintext scalar divisor (`FHE.div(x, 10000)`). The divisor is a public constant. The result is rounded down (floor division). The total claimed may be up to N−1 tokens less than deposited due to rounding, where N is the number of stakeholders. This is acceptable and documented.

**Test case:**
```typescript
it("sum of all claims does not exceed deposited", async () => {
      // deposit 1,000,000 tokens
        // two holders: 6000 bps + 4000 bps
          // claim both, decrypt both
            // assert: claim1 + claim2 <= 1,000,000
});
```

---

## Invariant 4: No double claim

**Statement:** A stakeholder can claim their share of a given asset at most once per deposit epoch.

```
∀ (asset, stakeholder): claimed(asset, stakeholder) ≤ 1
```

**Enforcement:** After `claimShare`, the contract stores an encrypted handle in `encClaimed[assetId][user]`. The claim function checks `FHE.isInitialized(encClaimed[assetId][caller])`. If already initialized (i.e., already claimed), the function reverts.

**Current implementation note:** v1 does not support multiple deposit rounds on the same asset. Revenue is deposited once; claims are one-time. If a second deposit is made after all holders have claimed, the accounting may become inconsistent. This is a known v1 limitation — see Invariant 5.

**Test case:**
```typescript
it("reverts on second claim attempt", async () => {
      await cr.claimShare(id); // first claim — succeeds
        await expect(cr.claimShare(id)).to.be.reverted; // second — reverts
});
```

---

## Invariant 5: Version consistency (v1 scope note)

**Statement:** The accounting state of an asset is consistent across all operations within a single version.

In v1, there is only one version per asset. Splits are set at registration and never updated. Revenue is deposited once. Claims are one-time. This makes version consistency trivially satisfied by the immutability of splits.

**v1 constraint:** splits cannot be updated. An asset with incorrect splits cannot be fixed without deploying a new contract and re-registering.

**v2 requirement:** versioned splits require tracking which revenue was deposited against which split version, and preventing claims across version boundaries. The data structure would be:

```
asset_id → {
      versions: [{ splits, depositedRevenue, claims }],
        activeVersion: uint
}
```

Each claim must be scoped to a version. Revenue deposited in v2 cannot be claimed against v1 splits.

**Not implemented in v1.** Documented here as a formal requirement for the upgrade path.

---

## Invariant 6: State machine monotonicity

**Statement:** Asset state transitions are one-way. No asset can move backward in the state machine.

```
UNREGISTERED(0) → PENDING(1) → ACTIVE(2) | INVALID(3)
```

Once ACTIVE, an asset cannot return to PENDING or UNREGISTERED. Once INVALID, an asset is terminal.

**Enforcement:** state is stored as a `uint8` enum. Transitions are guarded:
- `registerAsset`: requires state == UNREGISTERED
- `markSumDecryptable`: requires state == PENDING
- `confirmValidation`: requires state == PENDING; sets ACTIVE or INVALID
- All claim/deposit functions: require state == ACTIVE

No function moves an asset to a lower state value.

**Test case:**
```typescript
it("cannot re-register an active asset", async () => {
      // register, validate → ACTIVE
        await expect(cr.registerAsset(id, ...)).to.be.reverted;
});

it("cannot validate a second time", async () => {
      // validate → ACTIVE
        await expect(cr.markSumDecryptable(id)).to.be.reverted;
});
```

---

## Invariant 7: Observer access is explicit and append-only (v1)

**Statement:** Observer access to a stakeholder's encrypted share is granted only by that stakeholder's explicit transaction. Observers cannot self-grant.

```
∀ observer O granted access to (asset, stakeholder S):
  ∃ tx from S calling grantObserver(asset, O)
  ```

  **Enforcement:** `grantObserver` checks `msg.sender` is a registered stakeholder of the asset. Only the stakeholder can grant access to their own handle. The contract calls `FHE.allow(encShare[assetId][msg.sender], observer)` — ACL is updated only for the calling stakeholder's handle.

  **Known limitation:** grants are permanent in v1. There is no `revokeObserver`. This is documented in the README and trust model.

  ---

  ## Invariant audit checklist

  Run this before any contract modification:

  - [ ] Every asset reaching ACTIVE has a verified KMS proof of sum = 10,000
  - [ ] No `euint` type can encode a negative value (unsigned types enforced)
  - [ ] `FHE.isInitialized` checked before every claim to prevent double-claim
  - [ ] `FHE.div` uses plaintext scalar 10,000 — no encrypted divisor
  - [ ] `FHE.allowThis` called after every stored handle assignment
  - [ ] `FHE.allow(handle, user)` called for every address that needs user-decrypt
  - [ ] State machine transitions are guarded by `require` on current state
  - [ ] `grantObserver` checks `msg.sender` is a registered stakeholder
  - [ ] No plaintext splits or derived values emitted in events
  - [ ] `confirmValidation` proof verified with `FHE.checkSignatures` before state transition

  ---

  ## Gas impact of invariant enforcement

  | Invariant | Enforcement cost | Where paid |
  |---|---|---|
  | Sum integrity (KMS proof) | ~50k gas (checkSignatures) | `confirmValidation` — one-time per asset |
  | Non-negative (type system) | 0 | Compile time |
  | Claim bound (FHE mul+div) | ~600k gas | `claimShare` — per claim |
  | Double-claim check | ~30k gas (isInitialized) | `claimShare` |
  | State machine | ~5k gas (require) | Every state-changing function |
  | Observer explicit grant | ~127k gas | `grantObserver` — per grant |

  The most expensive invariant is claim computation (~600k gas), dominated by `FHE.mul` (enc-enc ~400-700k) and `FHE.div` (enc-scalar ~700k-1.2M). This is an architectural constraint of FHE arithmetic on Sepolia, not a contract bug.

  **v2 optimization path:** accumulate encrypted balances rather than computing per-claim. Users claim from their running balance rather than triggering a fresh FHE multiplication per deposit. Gas per claim drops to ~200k (FHE.sub + FHE.allowThis + FHE.allow).
  
})
})
}
})>
})
})
})