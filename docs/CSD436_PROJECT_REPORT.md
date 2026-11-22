# CSD436 Course Project Mapping & Technical Report
**Course:** CSD436 - Blockchain Technologies (Monsoon 2026)  
**Instructor:** Prof. Sweta Mishra  
**Institution:** Shiv Nadar Institution of Eminence (SNU)  
**Project:** Blockchain-Based IP & Research Data Sharing Platform (Hyperledger Fabric + IPFS + WebCrypto)

---

## 1. Executive Summary & Alignment with CSD436 Notes

This project implements an enterprise-grade, consortium blockchain platform for cross-institutional research IP and dataset sharing between universities (e.g., **Shiv Nadar University (`snu`)** and **IIT Delhi (`iitd`)**).

The design directly reflects the foundational concepts taught in CSD436:
1. **Permissioned Consortium Architecture:** Eliminates public blockchain pitfalls (energy-intensive PoW, transaction latency, lack of confidentiality, and storage bloat) using **Hyperledger Fabric**.
2. **Execute-Order-Validate Pipeline:** Replaces Ethereum/Bitcoin's sequential Order-Execute model with parallel chaincode execution, deterministic Raft ordering, and MVCC validation.
3. **Decentralized Identity (DID) & Local MSP:** Uses W3C-compliant DIDs (`did:fabric:snu:alice`) backed by client-side asymmetric cryptography (ECDSA P-256) and challenge-response authentication.
4. **Off-Chain Encrypted Storage & On-Chain Hash Verification:** Solves the blockchain storage constraint by storing AES-256-GCM encrypted payloads on IPFS and anchoring 64-character SHA-256 integrity digests on Fabric.
5. **Multi-Party Departmental Consensus:** Requires departmental sign-off for research asset mutations, locking the asset in state until all approvers commit.

---

## 2. Theoretical Mapping to Lecture Concepts

### 2.1 Public Blockchain Challenges vs. Our Fabric Solution (Slides 3–7)

| Public Blockchain Challenge (Slides) | Manifestation in Public Chains | Our Implementation Solution |
| :--- | :--- | :--- |
| **Low Performance & Scalability** | Low TPS (Bitcoin ~7, Ethereum ~15-30) | Fabric parallel endorsement + Raft consensus allows hundreds of TPS. |
| **Limited Privacy & Confidentiality** | Transparent UTXO/accounts; all nodes see amounts & payloads | AES-256-GCM client-side encryption + IPFS + RBAC access controls. |
| **Storage Constraints** | Every node replicates full block history; huge storage overhead | **Off-chain hybrid model**: Only metadata, CID, and SHA-256 hashes reside on Fabric; encrypted bulk data resides on IPFS. |
| **Unsustainable Consensus** | Proof-of-Work (PoW) mining wastes vast electrical power | Crash Fault Tolerant (CFT) **Raft** ordering service (zero mining, instant finality). |
| **Lack of Governance & Identity** | Pseudonymous addresses; no accountability | Identifiable participants via DIDs (`snu`, `iitd`), Organization MSPs, and Chaincode RBAC. |

---

### 2.2 Hyperledger Fabric Core Components Mapping (Slides 8–12, 33–43)

```
                    +------------------------------------------------+
                    |                   CHANNELS                     |
                    |   (Private communication layer: "mychannel")   |
                    +-----------------------+------------------------+
                                            |
         +----------------------------------+----------------------------------+
         |                                                                     |
+--------v--------+                                                   +--------v--------+
|    ORG 1 (snu)  |                                                   |   ORG 2 (iitd)  |
|  - Peer0 (End.) |                                                   |  - Peer0 (End.) |
|  - Local MSP    |                                                   |  - Local MSP    |
|  - Chaincode    |                                                   |  - Chaincode    |
+--------+--------+                                                   +--------+--------+
         |                                                                     |
         +----------------------------------+----------------------------------+
                                            |
                                 +----------v----------+
                                 |   ORDERING SERVICE  |
                                 |   (Raft Consensus)  |
                                 |   orderer.example   |
                                 +---------------------+
```

1. **Certificate Authority (CA) & MSP (Membership Service Provider)**:
   - *Course Note:* MSP validates X.509 certs from CAs to enforce identity and access control policies.
   - *Codebase:* Fabric identities are configured in `scripts/env.sh` and `backend/src/main/resources/application.yml` (`Org1MSP`, `Org2MSP`). In addition, the chaincode (`chaincode/research-ip/identity.go`) implements an on-chain DID Document registry storing ECDSA P-256 public keys.
2. **Peers (Endorsing vs. Committing)**:
   - *Course Note:* Endorsing peers simulate proposals without ledger writes; Committing peers validate endorsement policies and MVCC checks before appending to ledger.
   - *Codebase:* In `scripts/test-chaincode.sh` and `backend/src/main/java/com/researchip/config/FabricConfig.java`, transaction proposals are submitted to `peer0.org1.example.com` (7051) and `peer0.org2.example.com` (9051) for endorsement, then forwarded to `orderer.example.com` (7050).
3. **Ordering Service**:
   - *Course Note:* Gathers endorsed transactions, establishes total order, and cuts blocks (Raft consensus).
   - *Codebase:* Raft orderer running on port 7050 orders transactions for the channel `mychannel`.
4. **Ledger Dual Structure**:
   - *Course Note:* Fabric ledger consists of **Blockchain (Block store)** (immutable log of all valid/invalid transactions) and **World State** (current key-value state).
   - *Codebase:* State is stored in CouchDB instances (`couchdb0` and `couchdb1`), enabling rich JSON queries across asset versions, DIDs, proposals, and provenance logs (`ASSET_*`, `DID_*`, `PROP_*`, `LOG_*`).

---

### 2.3 Execute-Order-Validate 7-Step Flow (Slides 18–23, 44–50)

In contrast to the classical **Order-Execute** architecture (which suffers from sequential execution latency and non-deterministic hazards), our platform strictly follows the Fabric 7-step lifecycle:

```
[Client SDK / Backend]
        |
        | 1. Propose Transaction (RegisterAsset / ProposeUpdate)
        v
[Endorsing Peers (Org1, Org2)]
        |
        | 2. Simulate Execution (Produce Read-Write / RW sets, calculate hashes)
        v
[Endorsing Peers]
        |
        | 3. Proposal Response (Signed RW set returned to Client)
        v
[Client SDK / Backend]
        |
        | 4. Submit Endorsed Transaction to Ordering Service
        v
[Ordering Node (Raft)]
        |
        | 5. Cut Block & Deliver to Committing Peers
        v
[Committing Peers]
        |
        | 6. Validate:
        |    a) Endorsement policy check (Both Org1 and Org2 signed?)
        |    b) MVCC Read-Write conflict check
        |    c) Append block to Block Store; commit valid RW sets to World State (CouchDB)
        v
[Committing Peers]
        |
        | 7. Notify Application (Events / Commit Confirmation)
        v
[Client / UI Updates]
```

#### Code Implementation of the 7 Steps:
- **Steps 1–3 (Execution & Endorsement):** Initiated via Fabric Gateway in `backend/src/main/java/com/researchip/service/FabricService.java` (`contract.submitTransaction(...)`). The chaincode in Go (`chaincode/research-ip/asset.go`) simulates state transitions without touching storage.
- **Steps 4–5 (Ordering & Block Delivery):** The Fabric Gateway automatically transmits endorsements to `orderer.example.com:7050`, which creates blocks.
- **Step 6 (Validation & MVCC Check):** Committing peers check the read-set version (`expectedVersion` in `chaincode/research-ip/asset.go`). If two users try to approve or modify an asset concurrently, Fabric rejects the second transaction with `MVCC_READ_CONFLICT`.
- **Step 7 (Notification):** The gateway awaits block commit status before returning JSON results to the Spring Boot backend.

---

### 2.4 Cryptographic Building Blocks Used in the Project (Slides 13, 21, 31–43)

```
+-------------------------------------------------------------------------------+
|                             CRYPTOGRAPHY IN CSD436                            |
+---------------------------------------+---------------------------------------+
|            DATA INTEGRITY             |           PRIVACY & SECURITY          |
+---------------------------------------+---------------------------------------+
| - SHA-256 Hashing                     | - AES-256-GCM Symmetric Encryption    |
| - ECDSA P-256 Digital Signatures      | - Zero-Knowledge Challenge-Response   |
| - Fabric Ledger Immutability          | - TLS (Handshake + Record Layer)      |
| - Versioned State Verification        | - Role-Based Access Control (RBAC)    |
+---------------------------------------+---------------------------------------+
```

1. **Digital Signatures & Identity (ECDSA P-256 + SHA-256)**:
   - *Implementation:* `frontend/src/crypto.js` and `backend/src/main/java/com/researchip/service/AuthService.java`.
   - The user generates an EC keypair (`P-256`) in the browser using the WebCrypto API.
   - The private key stays inside `localStorage` / key backup file.
   - When logging in, the backend issues a 32-byte cryptographic nonce (`randomHex(32)`). The frontend signs it with `SHA256withECDSAinP1363Format`. The backend validates the signature against the on-chain public key stored on Fabric.
2. **Symmetric Encryption (AES-256-GCM) & Authenticated Data (AAD)**:
   - *Implementation:* `backend/src/main/java/com/researchip/service/CryptoService.java`.
   - Generates a per-asset key using `HMAC-SHA256(MASTER_KEY, "asset:" + assetId)`.
   - Encrypts files with AES-256-GCM with a 12-byte random Initialization Vector (IV) and a 16-byte authentication tag.
   - Binds `assetId` as Additional Authenticated Data (AAD) to prevent ciphertext transplant attacks.
3. **Data Integrity & Off-Chain Storage (SHA-256 + IPFS)**:
   - Before encryption, the backend computes the raw file's SHA-256 digest.
   - The encrypted ciphertext is stored on IPFS (`IpfsService.java`), yielding an immutable Content Identifier (CID).
   - Fabric records `{ assetId, cid, sha256_hash, classification, version }`.
   - When a user downloads the file, the backend decrypts it and verifies that `SHA256(decrypted_bytes) == ledger_hash`. If any bit was modified, the UI flags `COMPROMISED`.

---

## 3. Advanced Connections & Future Work (From Slides 26–30, 51–53)

Prof. Mishra's slides highlight two advanced privacy concepts that directly map to the future evolution of this platform:

### 3.1 Private Data Collections (PDC) vs. Off-Chain IPFS (Slides 26–27)
- *Class Note:* In Fabric PDC, confidential data is shared point-to-point only between authorized peers; only a **cryptographic hash** of the private data is committed to the shared blockchain ledger.
- *Our Project:* Applies this exact architectural pattern at the application level: IPFS stores the encrypted payload, while Fabric stores the cryptographic SHA-256 hash and metadata. This protects large research datasets from bloating the blockchain while guaranteeing immutability and provenance.

### 3.2 Proxy Re-Encryption (PRE) for Cross-University Sharing (Slide 51)
- *Class Note:* PRE allows an untrusted third party (proxy) to transform a ciphertext encrypted under user $A$'s public key ($pk_A$) into a ciphertext decryptable by user $B$'s private key ($sk_B$) using a re-encryption key $rk_{A \to B}$, without decrypting or revealing plaintext.
- *Application to our platform:* Currently, cross-university sharing uses backend-mediated key derivation (`MASTER_KEY`). Incorporating PRE (as demonstrated in Prof. Mishra's BCCA 2025 paper) would allow researcher Alice (`snu`) to delegate access directly to researcher Carol (`iitd`) with zero-trust server architecture.

---

## 4. Viva / Evaluation Q&A Guide

### Q1: Why did you choose Hyperledger Fabric instead of Ethereum or Bitcoin?
> **Answer:** As highlighted in our CSD436 notes, public blockchains like Bitcoin and Ethereum suffer from low throughput, transaction fees (gas), public transaction exposure, and storage constraints. Research IP sharing requires enterprise-grade confidentiality, identifiable participants (universities like SNU and IITD), high TPS, and deterministic latency without PoW mining. Fabric provides a permissioned consortium model with pluggable Raft consensus and channel-based access control.

### Q2: Explain the Execute-Order-Validate flow in your platform.
> **Answer:** 
> 1. **Execute (Endorsement):** When a user uploads or updates an asset, the client submits a proposal to Org1 and Org2 peers, which execute the chaincode in simulation and produce a Read-Write (RW) set and endorsement signature.
> 2. **Order:** The client collects endorsements and passes the transaction to the Raft ordering service, which groups transactions into blocks.
> 3. **Validate:** Committing peers verify the endorsement policy (both orgs approved), check RW sets against world state versions (MVCC check) to prevent concurrent conflicts, commit valid transactions to CouchDB, and append the block to the ledger.

### Q3: How do you handle large files given blockchain storage constraints?
> **Answer:** Blockchains are not designed for large binary datasets. In accordance with the off-chain storage pattern discussed in class, the raw file is hashed (SHA-256) and encrypted (AES-256-GCM). The encrypted bytes are stored off-chain on IPFS (Kubo), and only the IPFS CID and SHA-256 integrity hash are anchored on Fabric's world state and block store.

### Q4: How is Multi-Version Concurrency Control (MVCC) utilized in your update proposal flow?
> **Answer:** When Alice proposes an update, the asset is locked (`Status = PENDING_UPDATE`) and tagged with `BaseVersion`. When peer Bob approves the update, the chaincode verifies that the asset's current version matches `BaseVersion`. If another transaction attempts to modify the asset simultaneously, Fabric's validation phase flags a read-write conflict (`MVCC_READ_CONFLICT`), ensuring atomic, serialized consensus.
