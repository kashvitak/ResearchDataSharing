// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ResearchAsset  -  "Who owns it, what is its hash, what happened to it?"
 * -----------------------------------------------------------------------------
 * Solidity version of our *Research Asset chaincode* on Hyperledger Fabric.
 * The file itself is AES-256-GCM encrypted and kept on IPFS; only the CID,
 * the content hash and ownership/provenance live here.
 *
 * DEPARTMENT PEER VERIFICATION
 *   A change to an asset is never applied directly. proposeUpdate() opens a
 *   proposal; EVERY other approver of the owning department must call
 *   approveUpdate(). Only the last approval commits the new CID/hash.
 *   One rejectUpdate() kills the proposal. (On Fabric we get the same effect
 *   with a key-level / state-based endorsement policy on the asset key.)
 *
 * CONCURRENCY CONTROL (the interesting part)
 *   Example: Prof A (SNU-CSE) updates dataset D, while Prof B (SNU-CSE) also
 *   tries to update D, and Prof C (IITD-ECE, cross-university collaborator)
 *   reads D at the same moment.
 *
 *   1. Optimistic version check (lost-update protection)
 *      Every write carries `expectedVersion`, the version the caller read.
 *      If D moved on since then -> revert StaleVersion. Nobody overwrites a
 *      change they never saw.                     (= Fabric MVCC read-set check)
 *
 *   2. Update lock (write-write conflict)
 *      While A's proposal is open, D.status = PENDING_UPDATE. B's
 *      proposeUpdate / transferAsset revert with AssetLocked(A, nonce).
 *      B must wait for the vote to finish, re-read and retry.
 *
 *   3. Read-committed reads (read-write conflict)
 *      C's accessAsset() during the vote returns the LAST COMMITTED version
 *      plus pendingUpdate = true. C never sees half-approved data, and C's
 *      read does not block A. Reads by two universities at once never
 *      conflict with each other (read-read).
 *
 *   4. Quorum snapshot
 *      The number of approvals needed is frozen when the proposal opens, so
 *      an admin adding/removing members mid-vote can't change the rules.
 *
 *   5. Proposal nonce
 *      Approvals name the proposal nonce. An approval signed for an old,
 *      already-closed proposal can't be replayed onto a new one. The nonce is
 *      per asset (no global counter), so updates to different assets share no
 *      storage and can run in parallel - the key idea from the lecture paper.
 *
 *   6. Deadline + expireProposal()
 *      If a voter never responds, anyone can release the lock after the
 *      deadline - no permanent lock / deadlock.
 */

interface IRBAC {
    function hasPermission(address user, uint16 perm) external view returns (bool);
    function memberOf(address user)
        external
        view
        returns (bytes32 org, bytes32 dept, uint8 role, uint64 version, bool active);
    function deptApprovers(bytes32 key) external view returns (uint32);
    function deptKey(bytes32 org, bytes32 dept) external pure returns (bytes32);
}

contract ResearchAsset {
    uint16 private constant UPLOAD = 1;
    uint16 private constant READ = 2;
    uint16 private constant TRANSFER = 4;
    uint16 private constant AUDIT = 16;
    uint16 private constant APPROVE = 32;
    uint16 private constant TRANSFER_IN_ORG = 128;

    uint64 public constant VOTING_WINDOW = 3 days;

    enum Status { NONE, ACTIVE, PENDING_UPDATE }

    struct Asset {
        address owner;
        bytes32 org;
        bytes32 dept;
        string  cid;            // IPFS CID of the encrypted file
        bytes32 contentHash;    // SHA-256 of the file, used for integrity checks
        uint8   classification; // 0 public, 1 internal, 2 confidential
        uint64  version;        // committed version
        uint64  updatedAt;
        Status  status;
    }

    struct Proposal {
        address proposer;
        string  newCid;
        bytes32 newHash;
        uint64  baseVersion;    // version the proposer read
        uint64  nonce;
        uint64  deadline;
        uint32  required;       // snapshot of approvals needed
        uint32  approvals;
        bool    open;
    }

    struct Provenance {
        bytes32 action;         // "REGISTER", "UPDATE", "ACCESS", "TRANSFER", ...
        address actor;
        uint64  version;
        uint64  at;
    }

    IRBAC public immutable rbac;

    mapping(bytes32 => Asset) private assets;
    mapping(bytes32 => Proposal) private proposals;
    mapping(bytes32 => mapping(uint64 => mapping(address => bool))) private voted; // asset => nonce => voter
    mapping(bytes32 => mapping(address => bool)) public readGrant;  // cross-org read access
    mapping(bytes32 => Provenance[]) private history;

    error AssetExists();
    error UnknownAsset();
    error NotAuthorized();
    error NotOwner();
    error NotSameDepartment();
    error AssetLocked(address proposer, uint64 nonce);
    error StaleVersion(uint64 expected, uint64 actual);
    error NoOpenProposal();
    error StaleProposal(uint64 given, uint64 current);
    error ProposerCannotVote();
    error AlreadyVoted();
    error ProposalExpired();
    error ProposalNotExpired();

    event AssetRegistered(bytes32 indexed id, address indexed owner, string cid, bytes32 contentHash);
    event UpdateProposed(bytes32 indexed id, uint64 nonce, address indexed proposer, uint32 required);
    event UpdateApproved(bytes32 indexed id, uint64 nonce, address indexed voter, uint32 approvals);
    event UpdateRejected(bytes32 indexed id, uint64 nonce, address indexed voter, string reason);
    event UpdateCommitted(bytes32 indexed id, uint64 newVersion, string cid, bytes32 contentHash);
    event ProposalExpiredEvt(bytes32 indexed id, uint64 nonce);
    event AssetAccessed(bytes32 indexed id, address indexed reader, uint64 version, bool pendingUpdate);
    event AccessGranted(bytes32 indexed id, address indexed grantee);
    event AssetTransferred(bytes32 indexed id, address indexed from, address indexed to, uint64 version);

    constructor(address rbac_) {
        rbac = IRBAC(rbac_);
    }

    // ============================================================ modifiers

    modifier can(uint16 perm) {
        if (!rbac.hasPermission(msg.sender, perm)) revert NotAuthorized();
        _;
    }

    /// write-write guard: nothing may touch an asset while a vote is running
    modifier whenUnlocked(bytes32 id) {
        Proposal storage p = proposals[id];
        if (p.open) revert AssetLocked(p.proposer, p.nonce);
        _;
    }

    /// lost-update guard: caller must have seen the latest committed version
    modifier atVersion(bytes32 id, uint64 expectedVersion) {
        uint64 v = assets[id].version;
        if (v != expectedVersion) revert StaleVersion(expectedVersion, v);
        _;
    }

    // ============================================================== asset life

    function registerAsset(bytes32 id, string calldata cid, bytes32 contentHash, uint8 classification)
        external
        can(UPLOAD)
    {
        if (assets[id].status != Status.NONE) revert AssetExists();
        (bytes32 org, bytes32 dept, , , ) = rbac.memberOf(msg.sender);

        assets[id] = Asset({
            owner: msg.sender,
            org: org,
            dept: dept,
            cid: cid,
            contentHash: contentHash,
            classification: classification,
            version: 1,
            updatedAt: uint64(block.timestamp),
            status: Status.ACTIVE
        });
        _log(id, "REGISTER", 1);
        emit AssetRegistered(id, msg.sender, cid, contentHash);
    }

    /// @notice Step 1 of a peer-verified change. Locks the asset.
    function proposeUpdate(bytes32 id, string calldata newCid, bytes32 newHash, uint64 expectedVersion)
        external
        can(UPLOAD)
        whenUnlocked(id)
        atVersion(id, expectedVersion)
        returns (uint64 nonce)
    {
        Asset storage a = _existing(id);
        _requireSameDept(a);

        Proposal storage p = proposals[id];
        nonce = p.nonce + 1;  // per-asset nonce: no global counter, so updates on
                              // DIFFERENT assets never touch the same storage slot
        p.proposer = msg.sender;
        p.newCid = newCid;
        p.newHash = newHash;
        p.baseVersion = expectedVersion;
        p.nonce = nonce;
        p.deadline = uint64(block.timestamp) + VOTING_WINDOW;
        p.required = _quorum(a);
        p.approvals = 0;
        p.open = true;
        a.status = Status.PENDING_UPDATE;

        _log(id, "PROPOSE", a.version);
        emit UpdateProposed(id, nonce, msg.sender, p.required);

        if (p.required == 0) _commit(id, a, p); // single-member department
    }

    /// everyone else in the department must approve (the proposer counts as yes);
    /// the number is frozen here so membership changes mid-vote can't move it
    function _quorum(Asset storage a) private view returns (uint32 required) {
        required = rbac.deptApprovers(rbac.deptKey(a.org, a.dept));
        if (rbac.hasPermission(msg.sender, APPROVE) && required > 0) required -= 1;
    }

    /// @notice Step 2: each department peer verifies the new file/hash and signs off.
    function approveUpdate(bytes32 id, uint64 nonce) external can(APPROVE) {
        Asset storage a = _existing(id);
        Proposal storage p = _openProposal(id, nonce);
        _requireSameDept(a);
        if (msg.sender == p.proposer) revert ProposerCannotVote();
        if (voted[id][nonce][msg.sender]) revert AlreadyVoted();

        voted[id][nonce][msg.sender] = true;
        p.approvals += 1;
        emit UpdateApproved(id, nonce, msg.sender, p.approvals);

        if (p.approvals >= p.required) _commit(id, a, p);
    }

    /// @notice Any single department peer can veto. Unlocks the asset.
    function rejectUpdate(bytes32 id, uint64 nonce, string calldata reason) external can(APPROVE) {
        Asset storage a = _existing(id);
        Proposal storage p = _openProposal(id, nonce);
        _requireSameDept(a);

        p.open = false;
        a.status = Status.ACTIVE;
        _log(id, "REJECT", a.version);
        emit UpdateRejected(id, nonce, msg.sender, reason);
    }

    /// @notice Release a lock nobody finished voting on. Callable by anyone.
    function expireProposal(bytes32 id) external {
        Asset storage a = _existing(id);
        Proposal storage p = proposals[id];
        if (!p.open) revert NoOpenProposal();
        if (block.timestamp <= p.deadline) revert ProposalNotExpired();

        p.open = false;
        a.status = Status.ACTIVE;
        _log(id, "EXPIRE", a.version);
        emit ProposalExpiredEvt(id, p.nonce);
    }

    /// @notice Logged read. Same department, explicit grant, or auditor.
    /// Always returns the last COMMITTED data, even during a vote.
    function accessAsset(bytes32 id)
        external
        can(READ)
        returns (string memory cid, bytes32 contentHash, uint64 version, bool pendingUpdate)
    {
        Asset storage a = _existing(id);
        if (!_sameDept(a) && !readGrant[id][msg.sender] && !rbac.hasPermission(msg.sender, AUDIT)) {
            revert NotAuthorized();
        }
        pendingUpdate = proposals[id].open;
        _log(id, "ACCESS", a.version);
        emit AssetAccessed(id, msg.sender, a.version, pendingUpdate);
        return (a.cid, a.contentHash, a.version, pendingUpdate);
    }

    /// @notice Owner lets a researcher from another university read the asset.
    function grantAccess(bytes32 id, address grantee) external {
        Asset storage a = _existing(id);
        if (a.owner != msg.sender) revert NotOwner();
        if (!rbac.hasPermission(grantee, READ)) revert NotAuthorized();
        readGrant[id][grantee] = true;
        _log(id, "GRANT", a.version);
        emit AccessGranted(id, grantee);
    }

    /// @notice Hand ownership to another member (e.g. university -> industry partner).
    /// Project leads/admins can transfer anywhere; researchers only inside their own org.
    function transferAsset(bytes32 id, address newOwner, uint64 expectedVersion)
        external
        whenUnlocked(id)
        atVersion(id, expectedVersion)
    {
        Asset storage a = _existing(id);
        if (a.owner != msg.sender) revert NotOwner();
        (a.org, a.dept) = _transferTarget(a.org, newOwner);

        a.owner = newOwner;
        a.version += 1;
        a.updatedAt = uint64(block.timestamp);
        _log(id, "TRANSFER", a.version);
        emit AssetTransferred(id, msg.sender, newOwner, a.version);
    }

    /// full TRANSFER: anywhere. TRANSFER_IN_ORG ("limited"): only inside the same org.
    function _transferTarget(bytes32 assetOrg, address newOwner) private view returns (bytes32 org, bytes32 dept) {
        bool active;
        (org, dept, , , active) = rbac.memberOf(newOwner);
        if (!active) revert NotAuthorized();
        bool full = rbac.hasPermission(msg.sender, TRANSFER);
        bool inOrg = rbac.hasPermission(msg.sender, TRANSFER_IN_ORG) && org == assetOrg;
        if (!full && !inOrg) revert NotAuthorized();
    }

    // =================================================================== views

    /// @notice Compare a downloaded file's hash with the registered one.
    function verifyIntegrity(bytes32 id, bytes32 hashOfDownloadedFile) external view returns (bool) {
        return assets[id].status != Status.NONE && assets[id].contentHash == hashOfDownloadedFile;
    }

    function getAsset(bytes32 id) external view returns (Asset memory) {
        return assets[id];
    }

    function getProposal(bytes32 id)
        external
        view
        returns (address proposer, uint64 nonce, uint64 baseVersion, uint32 required, uint32 approvals, bool open)
    {
        Proposal storage p = proposals[id];
        return (p.proposer, p.nonce, p.baseVersion, p.required, p.approvals, p.open);
    }

    function getHistory(bytes32 id) external view returns (Provenance[] memory) {
        return history[id];
    }

    // ================================================================ internal

    function _commit(bytes32 id, Asset storage a, Proposal storage p) private {
        // defence in depth: base version must still be the committed one
        if (a.version != p.baseVersion) revert StaleVersion(p.baseVersion, a.version);

        a.cid = p.newCid;
        a.contentHash = p.newHash;
        a.version += 1;
        a.updatedAt = uint64(block.timestamp);
        a.status = Status.ACTIVE;
        p.open = false;

        _log(id, "UPDATE", a.version);
        emit UpdateCommitted(id, a.version, a.cid, a.contentHash);
    }

    function _existing(bytes32 id) private view returns (Asset storage a) {
        a = assets[id];
        if (a.status == Status.NONE) revert UnknownAsset();
    }

    function _openProposal(bytes32 id, uint64 nonce) private view returns (Proposal storage p) {
        p = proposals[id];
        if (!p.open) revert NoOpenProposal();
        if (p.nonce != nonce) revert StaleProposal(nonce, p.nonce);
        if (block.timestamp > p.deadline) revert ProposalExpired();
    }

    function _sameDept(Asset storage a) private view returns (bool) {
        (bytes32 org, bytes32 dept, , , bool active) = rbac.memberOf(msg.sender);
        return active && org == a.org && dept == a.dept;
    }

    function _requireSameDept(Asset storage a) private view {
        if (!_sameDept(a)) revert NotSameDepartment();
    }

    function _log(bytes32 id, bytes32 action, uint64 version) private {
        history[id].push(Provenance(action, msg.sender, version, uint64(block.timestamp)));
    }
}
