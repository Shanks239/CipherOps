// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// ─────────────────────────────────────────────────────────────────────────────
// IConfidentialToken
// Minimal interface. Swap in real ERC-7984 for production.
// ─────────────────────────────────────────────────────────────────────────────
interface IConfidentialToken {
    function confidentialTransfer(address to, euint128 amount) external;
    function balanceOf(address account) external view returns (euint128);
}

// ─────────────────────────────────────────────────────────────────────────────
// MockConfidentialToken
// Test/demo only. Pre-fund ConfidentialRoyalty address via mintPlaintext()
// in test setup. No proof required for minting — mock privilege.
// ─────────────────────────────────────────────────────────────────────────────
contract MockConfidentialToken is ZamaEthereumConfig, IConfidentialToken {
    mapping(address => euint128) private _balances;

    event Minted(address indexed to);
    event Transferred(address indexed from, address indexed to);

    /// @dev Test setup: mint plaintext amount to any address. Mock only.
    function mintPlaintext(address to, uint128 amount) external {
        euint128 enc = FHE.asEuint128(amount);
        if (!FHE.isInitialized(_balances[to])) {
            _balances[to] = enc;
        } else {
            _balances[to] = FHE.add(_balances[to], enc);
        }
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        emit Minted(to);
    }

    /// @dev Caller must allowTransient(amount, address(this)) before calling.
    ///      msg.sender's balance is debited; `to` is credited.
    function confidentialTransfer(address to, euint128 amount) external override {
        require(FHE.isInitialized(_balances[msg.sender]), "no balance");

        ebool ok = FHE.ge(_balances[msg.sender], amount);
        _balances[msg.sender] = FHE.select(
            ok,
            FHE.sub(_balances[msg.sender], amount),
            _balances[msg.sender]
        );

        if (!FHE.isInitialized(_balances[to])) {
            _balances[to] = FHE.select(ok, amount, FHE.asEuint128(0));
        } else {
            _balances[to] = FHE.select(
                ok,
                FHE.add(_balances[to], amount),
                _balances[to]
            );
        }

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        emit Transferred(msg.sender, to);
    }

    function balanceOf(address account) external view override returns (euint128) {
        return _balances[account];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ConfidentialRoyalty
//
// Encrypted royalty split distribution.
// - Splits (bps) stay encrypted from all parties including the contract operator.
// - Contract enforces splits sum to 10000 via async public decryption.
// - Revenue tracked as encrypted cumulative total; claims computed lazily.
// - Pull-based claim pattern: each stakeholder claims their own share.
// - No admin. No pause. No upgrade. Contract is the protocol.
//
// V1 LIMITATIONS:
// - depositRevenue records encrypted accounting only; does NOT pull tokens from
//   depositor. Pre-fund contract address in MockConfidentialToken via
//   mintPlaintext() before running claim tests.
// - Observer ACL grants are permanent (FHEVM has no revoke). Document in UI.
// - Max 8 stakeholders per asset (gas bound, empirically confirmed).
// ─────────────────────────────────────────────────────────────────────────────
contract ConfidentialRoyalty is ZamaEthereumConfig {

    // ── constants ────────────────────────────────────────────────────────────

    uint8   public constant MAX_STAKEHOLDERS = 8;
    uint16  public constant REQUIRED_SUM     = 10000;

    // ── types ────────────────────────────────────────────────────────────────

    enum AssetState { UNREGISTERED, PENDING, ACTIVE, INVALID }

    struct Asset {
        address   registrant;
        uint8     count;
        AssetState state;
        address[8]   stakeholders;
        euint16[8]   encShares;     // bps per stakeholder
        euint16      encSum;        // running sum used for validation
        euint128     encTotalRevenue;
        euint128[8]  encClaimed;    // per-stakeholder lifetime claimed
    }

    // ── storage ──────────────────────────────────────────────────────────────

    IConfidentialToken public immutable token;

    mapping(bytes32 => Asset)                            private _assets;
    mapping(bytes32 => mapping(address => address))      public  observers;
    mapping(bytes32 => bool)                             private _usedProofs;
    mapping(address => bytes32[])                        public  stakedAssets;

    // ── events ───────────────────────────────────────────────────────────────

    event AssetRegistered    (bytes32 indexed assetId, address indexed registrant, uint8 count);
    event SumMarkedDecryptable(bytes32 indexed assetId);
    event AssetActivated     (bytes32 indexed assetId);
    event AssetInvalid       (bytes32 indexed assetId, uint16 decryptedSum);
    event RevenueDeposited   (bytes32 indexed assetId, address indexed depositor);
    event ShareClaimed       (bytes32 indexed assetId, address indexed stakeholder);
    event ObserverGranted    (bytes32 indexed assetId, address indexed stakeholder, address indexed observer);

    // ── constructor ──────────────────────────────────────────────────────────

    constructor(address token_) {
        token = IConfidentialToken(token_);
    }

    // ── internal helpers ─────────────────────────────────────────────────────

    function _indexOf(bytes32 assetId, address who) internal view returns (uint8) {
        Asset storage a = _assets[assetId];
        for (uint8 i = 0; i < a.count; i++) {
            if (a.stakeholders[i] == who) return i;
        }
        revert("not stakeholder");
    }

    // ── registration ─────────────────────────────────────────────────────────

    /// @notice Register an asset with encrypted bps splits.
    /// @dev Single inputProof covers all encShares (same encryption session).
    ///      Gas: ~3.5–5M on Sepolia for 8 stakeholders.
    function registerAsset(
        bytes32                  assetId,
        address[]        calldata stakeholders,
        externalEuint16[] calldata encShares,
        bytes            calldata inputProof
    ) external {
        require(_assets[assetId].state == AssetState.UNREGISTERED, "exists");
        uint8 n = uint8(stakeholders.length);
        require(n >= 1 && n <= MAX_STAKEHOLDERS, "count out of range");
        require(encShares.length == n, "length mismatch");

        for (uint8 i = 0; i < n; i++) {
            require(stakeholders[i] != address(0), "zero address");
            for (uint8 j = i + 1; j < n; j++) {
                require(stakeholders[i] != stakeholders[j], "duplicate stakeholder");
            }
        }

        Asset storage a = _assets[assetId];
        a.registrant = msg.sender;
        a.count      = n;
        a.state      = AssetState.PENDING;

        euint16 runningSum;
        for (uint8 i = 0; i < n; i++) {
            a.stakeholders[i] = stakeholders[i];
            a.encShares[i]    = FHE.fromExternal(encShares[i], inputProof);
            FHE.allowThis(a.encShares[i]);

            if (i == 0) {
                runningSum = a.encShares[0];
            } else {
                runningSum = FHE.add(runningSum, a.encShares[i]);
                FHE.allowThis(runningSum);
            }
        }

        a.encSum = runningSum;
        FHE.allowThis(a.encSum);

        for (uint8 i = 0; i < n; i++) {
            stakedAssets[stakeholders[i]].push(assetId);
        }
        bool registrantIsStakeholder = false;
        for (uint8 i = 0; i < n; i++) {
            if (stakeholders[i] == msg.sender) { registrantIsStakeholder = true; break; }
        }
        if (!registrantIsStakeholder) stakedAssets[msg.sender].push(assetId);
        emit AssetRegistered(assetId, msg.sender, n);
    }

    // ── validation ───────────────────────────────────────────────────────────

    /// @notice Permissionless. Marks encSum for public decryption by the KMS.
    function markSumDecryptable(bytes32 assetId) external {
        require(_assets[assetId].state == AssetState.PENDING, "not pending");
        FHE.makePubliclyDecryptable(_assets[assetId].encSum);
        emit SumMarkedDecryptable(assetId);
    }

    /// @notice Submit the KMS decryption proof to activate or invalidate the asset.
    /// @dev Permissionless — proof is cryptographically self-validating.
    ///      Handle order in checkSignatures MUST match markSumDecryptable.
    function confirmValidation(
        bytes32        assetId,
        uint16         decryptedSum,
        bytes calldata decryptionProof
    ) external {
        Asset storage a = _assets[assetId];
        require(a.state == AssetState.PENDING, "not pending");

        bytes32 ph = keccak256(decryptionProof);
        require(!_usedProofs[ph], "replay");
        _usedProofs[ph] = true;

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(a.encSum);
        FHE.checkSignatures(handles, abi.encode(decryptedSum), decryptionProof);

        if (decryptedSum == REQUIRED_SUM) {
            a.state = AssetState.ACTIVE;
            for (uint8 i = 0; i < a.count; i++) {
                FHE.allow(a.encShares[i], a.stakeholders[i]);
            }
            emit AssetActivated(assetId);
        } else {
            a.state = AssetState.INVALID;
            emit AssetInvalid(assetId, decryptedSum);
        }
    }

    // ── revenue ──────────────────────────────────────────────────────────────

    /// @notice Record an encrypted revenue deposit against this asset.
    /// @dev V1: accounting only. Token transfer is handled separately.
    ///      In production ERC-7984: add confidentialTransferFrom here.
    function depositRevenue(
        bytes32            assetId,
        externalEuint128   encAmount,
        bytes     calldata inputProof
    ) external {
        require(_assets[assetId].state == AssetState.ACTIVE, "not active");

        euint128 amount = FHE.fromExternal(encAmount, inputProof);
        Asset storage a = _assets[assetId];

        if (!FHE.isInitialized(a.encTotalRevenue)) {
            a.encTotalRevenue = amount;
        } else {
            a.encTotalRevenue = FHE.add(a.encTotalRevenue, amount);
        }
        FHE.allowThis(a.encTotalRevenue);

        emit RevenueDeposited(assetId, msg.sender);
    }

    // ── claim ────────────────────────────────────────────────────────────────

    /// @notice Claim caller's share of accumulated revenue.
    /// @dev Lazy computation: entitlement = totalRevenue * share / 10000.
    ///      claimable = entitlement - alreadyClaimed.
    ///      Gas: ~2–3M on Sepolia (dominated by FHE.mul euint16 × euint128).
    function claimShare(bytes32 assetId) external {
        Asset storage a = _assets[assetId];
        require(a.state == AssetState.ACTIVE, "not active");
        require(FHE.isInitialized(a.encTotalRevenue), "no revenue");

        uint8 i = _indexOf(assetId, msg.sender);

        // entitlement = (share * totalRevenue) / 10000
        // mul(euint16, euint128) → euint128 confirmed in FHE.sol line 1940
        euint128 entitlement = FHE.div(
            FHE.mul(a.encShares[i], a.encTotalRevenue),
            uint128(REQUIRED_SUM)
        );

        // claimable = entitlement - previously claimed (underflow-guarded)
        euint128 claimable;
        if (!FHE.isInitialized(a.encClaimed[i])) {
            claimable = entitlement;
            a.encClaimed[i] = entitlement;
        } else {
            ebool underflow = FHE.lt(entitlement, a.encClaimed[i]);
            claimable = FHE.select(
                underflow,
                FHE.asEuint128(0),
                FHE.sub(entitlement, a.encClaimed[i])
            );
            a.encClaimed[i] = FHE.add(a.encClaimed[i], claimable);
        }

        FHE.allowThis(a.encClaimed[i]);
        FHE.allow(a.encClaimed[i], msg.sender);

        // Propagate to observer if one is registered
        address obs = observers[assetId][msg.sender];
        if (obs != address(0)) {
            FHE.allow(a.encClaimed[i], obs);
        }

        // Transfer from contract's pre-funded token balance to stakeholder
        FHE.allowTransient(claimable, address(token));
        token.confidentialTransfer(msg.sender, claimable);

        emit ShareClaimed(assetId, msg.sender);
    }

    // ── observer ─────────────────────────────────────────────────────────────

    /// @notice Grant an observer read access to caller's share and claimed total.
    /// @dev PERMANENT. ACL grants cannot be revoked in FHEVM v0.9.
    ///      If encClaimed not yet initialized (no prior claim), observer
    ///      receives the handle on next claimShare call automatically.
    function grantObserver(bytes32 assetId, address observer) external {
        Asset storage a = _assets[assetId];
        require(a.state == AssetState.ACTIVE, "not active");
        require(observer != address(0), "zero address");

        uint8 i = _indexOf(assetId, msg.sender);

        FHE.allow(a.encShares[i], observer);
        if (FHE.isInitialized(a.encClaimed[i])) {
            FHE.allow(a.encClaimed[i], observer);
        }

        observers[assetId][msg.sender] = observer;
        emit ObserverGranted(assetId, msg.sender, observer);
    }

    // ── views ────────────────────────────────────────────────────────────────

    function getAssetState(bytes32 assetId) external view returns (AssetState) {
        return _assets[assetId].state;
    }

    function getStakeholders(bytes32 assetId)
        external view returns (address[] memory addrs, uint8 count)
    {
        Asset storage a = _assets[assetId];
        addrs = new address[](a.count);
        for (uint8 i = 0; i < a.count; i++) addrs[i] = a.stakeholders[i];
        return (addrs, a.count);
    }

    function getEncShare(bytes32 assetId, address stakeholder)
        external view returns (euint16)
    {
        return _assets[assetId].encShares[_indexOf(assetId, stakeholder)];
    }

    function getEncClaimed(bytes32 assetId, address stakeholder)
        external view returns (euint128)
    {
        return _assets[assetId].encClaimed[_indexOf(assetId, stakeholder)];
    }

    function getEncTotalRevenue(bytes32 assetId)
        external view returns (euint128)
    {
        return _assets[assetId].encTotalRevenue;
    }
    function getStakedAssets(address user) external view returns (bytes32[] memory) {
        return stakedAssets[user];
    }

    function getEncSum(bytes32 assetId) external view returns (euint16) {
        return _assets[assetId].encSum;
    }
}

