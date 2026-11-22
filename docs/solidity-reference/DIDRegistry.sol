// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * DIDRegistry  -  "Who are you?"
 * -----------------------------------------------------------------------------
 * NOTE: Our real project runs on Hyperledger Fabric, where this logic is written
 * as the *Identity chaincode* (Go/Java). Fabric does not run Solidity, so this
 * contract is the Solidity version of the same logic, written for the
 * assignment (component 2c). Function names map 1:1 to the chaincode.
 *
 * Only the HASH of the public key is stored. The private key never touches the
 * chain - the researcher keeps it in their wallet.
 *
 * Concurrency: every DID document carries a `version`. Any write must pass the
 * version the caller last read (`expectedVersion`). If someone else changed the
 * document in between, the call reverts with StaleVersion instead of silently
 * overwriting it (optimistic concurrency control, same idea as Fabric MVCC).
 */
contract DIDRegistry {
    struct DIDDoc {
        address controller;   // account that owns the private key
        bytes32 pubKeyHash;   // keccak256 of the public verification key
        string  org;          // home organisation, e.g. "SNU"
        uint64  version;      // bumped on every write
        uint64  updatedAt;
        bool    active;
    }

    mapping(bytes32 => DIDDoc) private docs;   // keccak256(did string) => document
    mapping(address => bytes32) public didOf;  // controller => keccak256(did)

    error DIDAlreadyExists();
    error AccountAlreadyHasDID();
    error UnknownDID();
    error NotController();
    error DIDInactive();
    error StaleVersion(uint64 expected, uint64 actual);

    event DIDRegistered(bytes32 indexed didKey, string did, address indexed controller, string org);
    event KeyRotated(bytes32 indexed didKey, bytes32 newPubKeyHash, uint64 version);
    event DIDRevoked(bytes32 indexed didKey, uint64 version);

    // ------------------------------------------------------------------ writes

    /// @notice Create a DID such as "did:fabric:snu:prof_a" for msg.sender.
    function registerDID(string calldata did, bytes32 pubKeyHash, string calldata org)
        external
        returns (bytes32 didKey)
    {
        didKey = keccak256(bytes(did));
        if (docs[didKey].controller != address(0)) revert DIDAlreadyExists();
        if (didOf[msg.sender] != bytes32(0)) revert AccountAlreadyHasDID();

        docs[didKey] = DIDDoc({
            controller: msg.sender,
            pubKeyHash: pubKeyHash,
            org: org,
            version: 1,
            updatedAt: uint64(block.timestamp),
            active: true
        });
        didOf[msg.sender] = didKey;
        emit DIDRegistered(didKey, did, msg.sender, org);
    }

    /// @notice Replace the verification key (lost / compromised key).
    /// @param expectedVersion version the caller read before signing this tx.
    function rotateKey(string calldata did, bytes32 newPubKeyHash, uint64 expectedVersion) external {
        DIDDoc storage d = _ownedActive(did);
        _checkVersion(d.version, expectedVersion);

        d.pubKeyHash = newPubKeyHash;
        d.version += 1;
        d.updatedAt = uint64(block.timestamp);
        emit KeyRotated(keccak256(bytes(did)), newPubKeyHash, d.version);
    }

    /// @notice Permanently deactivate a DID (researcher leaves, key leaked, ...).
    function revokeDID(string calldata did, uint64 expectedVersion) external {
        DIDDoc storage d = _ownedActive(did);
        _checkVersion(d.version, expectedVersion);

        d.active = false;
        d.version += 1;
        d.updatedAt = uint64(block.timestamp);
        emit DIDRevoked(keccak256(bytes(did)), d.version);
    }

    // ------------------------------------------------------------------- reads

    function resolve(string calldata did) external view returns (DIDDoc memory) {
        DIDDoc memory d = docs[keccak256(bytes(did))];
        if (d.controller == address(0)) revert UnknownDID();
        return d;
    }

    /// @notice Used by RBACManager / ResearchAsset before every permission check.
    function isActive(address who) external view returns (bool) {
        bytes32 k = didOf[who];
        return k != bytes32(0) && docs[k].active;
    }

    /// @notice Off-chain challenge-response helper: backend checks the key a
    ///         user signed with is the one currently registered.
    function verifyKey(address who, bytes32 pubKeyHash) external view returns (bool) {
        DIDDoc storage d = docs[didOf[who]];
        return d.active && d.pubKeyHash == pubKeyHash;
    }

    // ---------------------------------------------------------------- internal

    function _ownedActive(string calldata did) private view returns (DIDDoc storage d) {
        d = docs[keccak256(bytes(did))];
        if (d.controller == address(0)) revert UnknownDID();
        if (d.controller != msg.sender) revert NotController();
        if (!d.active) revert DIDInactive();
    }

    function _checkVersion(uint64 actual, uint64 expected) private pure {
        if (actual != expected) revert StaleVersion(expected, actual);
    }
}
