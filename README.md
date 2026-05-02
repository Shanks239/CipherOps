# RoyaltyLayer

**Private royalty splits, enforced on-chain.**

Live: [royaltylayer.zoomfrez.xyz](https://royaltylayer.zoomfrez.xyz) · Contract: [Sepolia Etherscan](https://sepolia.etherscan.io/address/0x57FefEBE5598A6FbB8aaeA5909c0A703Fe09299F)

---

## The problem

Publishing a royalty split on-chain is publishing a business secret. Music executives have said it plainly: if competitors can see your deal structure, they'll undercut it. This isn't a theoretical concern. It's why rights-holders won't put real agreements on public ledgers, regardless of what the contract does with the numbers.

Story Protocol's own roadmap flags "Confidentiality" as active research. RoyaltyLayer builds what they haven't built yet.

## Why FHE specifically

Three parties need to stay honest about a set of percentages that must sum to 100%, but can't see each other's individual numbers. That constraint rules out most approaches:

- **Public ledger**: splits visible to everyone, including competitors
- **Commit-reveal**: the reveal step exposes the data
- **Public-key encryption**: the contract can't compute on ciphertext; it can only store it
- **ZK proofs**: proving N-party sum equality without revealing inputs is gas-prohibitive at this size
- **TEEs**: reintroduce a trusted operator, which is the thing you're trying to eliminate

FHE is the only option that lets the contract verify `sum = 10,000 bps` without ever seeing a single individual split. That's what RoyaltyLayer does.

## How it works

```
Rights-holders → encrypt BPS locally → send handles on-chain
Contract stores handles only (no plaintext ever)
KMS decrypts the encrypted SUM, returns proof
Contract verifies sum = 10,000 → asset goes ACTIVE
Revenue deposited as encrypted amount
Each holder claims independently; contract computes share in FHE
Holder signs EIP-712 → KMS returns plaintext only to them
```

Five steps in the demo. No step exposes another holder's split. Not even to the KMS.

## Contracts (Sepolia)

| Contract | Address |
|---|---|
| ConfidentialRoyalty | `0x57FefEBE5598A6FbB8aaeA5909c0A703Fe09299F` |
| MockConfidentialToken | `0x742626Ff76cAcf2426a9B300cE25efEe1981217e` |

## Gas (measured on Sepolia)

| Operation | Gas used |
|---|---|
| Register asset (2 stakeholders) | 424,403 |
| Deposit revenue | 185,854 |
| Claim share | 390,816 |
| Grant observer | 127,359 |

## Stack

- Solidity + [Zama FHEVM](https://www.zama.ai/fhevm) — encrypted types, FHE arithmetic on-chain
- Hardhat — compilation, deployment, tests
- ethers v6 — wallet connection, transaction signing
- Single-file frontend — no framework, ships as static HTML to Vercel

## Running locally

You need Node 18+, a Sepolia wallet with testnet ETH, and MetaMask or Rabby.

```bash
git clone https://github.com/Shanks239/CipherOps
cd CipherOps

# Install hardhat deps
npm install

# Serve the frontend
npx serve frontend -p 3000
```

Open `localhost:3000`. Connect wallet, switch to Sepolia, work through the five steps.

The WASM files required by the Zama SDK (`kms_lib_bg.wasm`, `tfhe_bg.wasm`) are committed to `frontend/`. They're large but necessary — the SDK won't init without them.

## Repo structure

```
CipherOps/
  cipherops/
    contracts/
      ConfidentialRoyalty.sol   # main contract
      BpsSumProbe.sol           # validation helper
    scripts/                    # deploy + interaction scripts
    test/                       # hardhat tests
  frontend/
    index.html                  # full app, single file
    sdk-bundle.js               # Zama relayer SDK, esbuild output
    ethers-bundle.js            # ethers v6, esbuild output
    *.wasm                      # FHEVM WASM binaries
    vercel.json                 # sets Content-Type for .wasm
```

## Known limitations

- Observer grants are permanent in v1. There's no revoke.
- Revenue token is a mock (mintable by anyone on testnet). Production would use a real ERC-20.
- Sepolia only. Zama's KMS isn't on mainnet yet.
- Splits are immutable after registration.

