# Blockchain-Based IP & Research Data Sharing Platform

A permissioned **Hyperledger Fabric** platform where universities, labs and industry partners register,
share, transfer and verify research assets (datasets, papers, code, models, designs).

```
DID (who are you?)  ->  RBAC (what may you do?)  ->  AES-256-GCM encrypted file on IPFS (where is it?)
                    ->  Hyperledger Fabric (who owns it, what is its hash, what happened to it?)
```

Extra rule from our mid-sem report: **a change to a shared asset only commits after every approver of the
owning department has signed off.** The asset is locked while the vote runs.

---

## 1. Architecture (kept simple)

```
 React (Vite, :5173)  -->  Spring Boot (:8080)  -->  Fabric Gateway  -->  Fabric test network
      |                        |                                           Org1 + Org2 + orderer
      | signs login            |-- encrypt / decrypt (AES-256-GCM)          chaincode "research" (Go)
      | challenge with         |-- SHA-256 hash                             state DB: CouchDB
      | its private key        '-- IPFS (Kubo, :5001)  <- ONLY encrypted bytes
```

| Layer | What it does | Folder |
|---|---|---|
| Chaincode (Go) | DID, RBAC, assets, voting, provenance - **all rules are enforced here** | `chaincode/research-ip` |
| Backend (Spring Boot) | DID login (challenge-response), encrypt + IPFS, calls chaincode | `backend` |
| Frontend (React) | Login, upload, download+verify, approve, admin | `frontend` |
| IPFS | Stores encrypted files | `docker-compose.yml` |
| Scripts | Install Fabric, start network, deploy chaincode, smoke test | `scripts` |

```
research-ip-platform/
├── chaincode/research-ip/   main.go models.go helpers.go identity.go rbac.go asset.go go.mod
├── backend/                 pom.xml, src/main/java/com/researchip/{config,service,web}
├── frontend/                package.json, vite.config.js, src/{App.jsx,api.js,crypto.js,styles.css}
├── scripts/                 setup-fabric.sh start-network.sh deploy-chaincode.sh test-chaincode.sh env.sh
├── docs/solidity-reference/ the assignment's Solidity versions (Fabric does NOT run these)
├── docker-compose.yml       IPFS only
└── README.md
```

---

## 2. Prerequisites

Linux, macOS, or Windows with **WSL2** (run everything inside WSL). You need:

| Tool | Version | Check |
|---|---|---|
| Docker + Docker Compose v2 | recent | `docker --version && docker compose version` |
| Go | 1.21+ | `go version` (needed on the host: Fabric vendors the chaincode before packaging) |
| JDK | 17+ | `java -version` |
| Maven | 3.9+ | `mvn -v` |
| Node.js | 18+ | `node -v` |
| curl, git, openssl, bash | any | |

Make sure your user can run Docker without `sudo` (`docker ps` works). Free ports: 7050, 7051, 9051, 8080, 5173, 5001.

---

## 3. Setup (first time, ~15-30 min because of image downloads)

Run all commands from the repo root unless stated otherwise.

```bash
chmod +x scripts/*.sh

# 1. Download Fabric docker images, binaries and fabric-samples (needs internet)
./scripts/setup-fabric.sh

# 2. Start the 2-org Fabric test network and create channel "mychannel"
./scripts/start-network.sh

# 3. Package, install, approve (both orgs) and commit the chaincode "research"
./scripts/deploy-chaincode.sh
```

**Optional smoke test of the chaincode** (recommended once, so you know the rules work before touching the UI):

```bash
./scripts/test-chaincode.sh
```

> The smoke test creates its own DIDs and initialises governance, which would clash with the UI demo.
> **After running it, reset:** `./scripts/start-network.sh && ./scripts/deploy-chaincode.sh`.

```bash
# 4. Start IPFS
docker compose up -d

# 5. Start the backend (new terminal)
cd backend
echo "export MASTER_KEY=$(openssl rand -base64 32)" > .env.sh   # create ONCE, keep it
source .env.sh
mvn spring-boot:run
# -> http://localhost:8080

# 6. Start the frontend (another terminal)
cd frontend
npm install
npm run dev
# -> open http://localhost:5173   (use "localhost", not your LAN IP: browser crypto needs a secure context)
```

Next time you only need: `docker compose up -d`, then `source backend/.env.sh && mvn spring-boot:run`, then `npm run dev`
(the Fabric network keeps running until you stop Docker; if you ran `network.sh down`, repeat steps 2-3 - the ledger is wiped).

> **Keep `backend/.env.sh`.** The `MASTER_KEY` derives every file's encryption key. Lose it and the stored files can never be decrypted.

---

## 4. Demo walkthrough (shows every feature)

People: governance `did:fabric:network:gov`, SNU admin `did:fabric:snu:admin`, researchers
`did:fabric:snu:alice` + `did:fabric:snu:bob`, IITD admin `did:fabric:iitd:admin`, collaborator `did:fabric:iitd:carol`.

1. **Register the six DIDs.** On the login screen type a DID -> *Register new DID* (a key backup downloads; the private
   key is also kept in this browser, one per DID).
2. **Governance.** Log in as `gov` -> *Admin* -> *Make me governance*. Log out and in again. Add organisation `snu`
   with admin `did:fabric:snu:admin`, then `iitd` with admin `did:fabric:iitd:admin`.
3. **Roles.** Log in as `snu:admin` -> *Admin* -> assign `alice` = `CSE` / `RESEARCHER`, `bob` = `CSE` / `RESEARCHER`.
   Log in as `iitd:admin` -> assign `carol` = `ECE` / `COLLABORATOR`.
4. **Upload.** Log in as `alice` -> *Upload* -> id `DS-001`, class `CONFIDENTIAL`, any file.
   (It is hashed, encrypted, stored on IPFS, and registered on Fabric.)
5. **Download + integrity.** Open `DS-001` -> *Download* -> "Integrity VALID". Then use *Verify a file you already have*
   with an edited copy -> "COMPROMISED".
6. **Peer approval.** As `alice`, *Propose new version* with a different file. The asset turns `PENDING_UPDATE` and is
   locked. Log in as `bob` -> open `DS-001` -> *Download proposed file* -> *Approve*. It commits as **v2**.
7. **Cross-university sharing.** As `alice`, paste `did:fabric:iitd:carol` -> *Grant read access*. Log in as `carol` ->
   she now sees and can download `DS-001`. (Before the grant she saw nothing.)
8. **RBAC in chaincode.** As `alice`, try *Transfer ownership* to `carol` -> denied (researchers may only transfer inside
   their own organisation). Transfer to `bob` works.
9. **Provenance.** The history table at the bottom lists every REGISTER / PROPOSE / APPROVE / UPDATE / ACCESS / GRANT / TRANSFER with DID and time.

---

## 5. Roles and permissions

Edit `rolePerms` in `chaincode/research-ip/rbac.go` to change this (then redeploy, see section 7).

| Role | Upload | Read | Transfer | Verify | Audit | Approve updates | Manage roles |
|---|---|---|---|---|---|---|---|
| ORG_ADMIN | yes | yes | yes | yes | yes | - | yes |
| PROJECT_LEAD | yes | yes | yes | yes | yes | yes | - |
| RESEARCHER | yes | yes | own org only | yes | - | yes | - |
| COLLABORATOR | - | yes | - | yes | - | - | - |
| AUDITOR | - | yes | - | yes | yes | - | - |

Who can **read** a given asset: members of the owning org+department, anyone the owner explicitly granted access to,
and `AUDITOR`s. (This differs slightly from the Solidity reference, where any role with `AUDIT` could read everything.)

---

## 6. What is in the chaincode

| Group | Functions |
|---|---|
| Identity | `CreateDID`, `GetDID`, `UpdatePublicKey` |
| RBAC | `InitNetwork`, `AddOrganization`, `AssignRole`, `RemoveRole`, `CheckPermission`, `GetMember`, `IsGovernance` |
| Assets | `RegisterAsset`, `GetAsset`, `ListAssets`, `AccessAsset` (logged read), `VerifyAsset`, `GetAssetHistory` |
| Voting | `ProposeUpdate`, `ApproveUpdate`, `RejectUpdate`, `ExpireProposal`, `GetProposal` |
| Sharing | `GrantAccess`, `TransferAsset` |

Concurrency rules (from the mid-sem design): every write carries `expectedVersion` (no lost updates); an asset is locked
while a vote runs; reads always return the last committed version; the number of approvals needed is frozen when the
proposal opens; proposals expire after 72 h so a lock can never be permanent; every log entry has its own key so audit
logging never conflicts.

Backend endpoints (all under `/api`, token in `Authorization: Bearer ...` except `/auth/*`):
`POST /auth/register | /auth/challenge | /auth/login`, `GET /me`, `POST /admin/init | /admin/organizations | /admin/roles`,
`DELETE /admin/roles?did=`, `GET/POST /assets`, `GET /assets/{id} | /history | /proposal | /download | /proposal/download`,
`POST /assets/{id}/verify | /propose | /approve | /reject | /expire | /grant | /transfer`.

---

## 7. Changing the chaincode

```bash
# edit chaincode/research-ip/*.go, then:
./scripts/deploy-chaincode.sh 1.1 2     # new version label, next sequence number (2, then 3, ...)
```

Existing ledger data stays. Restart the backend only if you changed the Java code.

---

## 8. Known simplifications (be upfront about these in your report)

1. **One Fabric identity for the whole backend.** The backend submits every transaction as Fabric user `Org1 User1` and
   passes the DID it authenticated as the first argument. Chaincode enforces RBAC on that DID, but it *trusts the backend*
   to have authenticated it. Production fix: enrol each user with Fabric CA (org/dept/role as certificate attributes) and
   read the caller from `ctx.GetClientIdentity()`.
2. **Organisations (`snu`, `iitd`) are logical names in the RBAC data.** The Fabric orgs are just the two test-network
   orgs; with the default policy both endorse every transaction. Mapping each university to its own Fabric org is a later step.
3. **Encryption keys live in the backend** (`MASTER_KEY` -> per-asset key). Whoever runs the backend can decrypt files.
   Production fix: KMS/HSM plus per-user key wrapping.
4. **Prototype security**: private key kept in browser `localStorage`, sessions in memory, plain HTTP on localhost.
5. **IPFS**: one local node. Files are encrypted, but the node joins the public IPFS network by default; use a private
   swarm and several pinning nodes for real use.
6. **Not included** (listed as future scope in your document): ABAC, verifiable credentials, zero-knowledge proofs,
   Fabric key-level endorsement policies and private data collections.
7. First caller of `InitNetwork` becomes governance - do it immediately after deployment.
8. I could not run Fabric, Maven or Go in the environment this repo was generated in, so the code has been syntax-checked
   but **not executed end to end**. Run `scripts/test-chaincode.sh` first; if something fails, copy the full error text when asking for help.

---

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `go: command not found` / vendoring error while deploying | Install Go 1.21+ on the host; rerun `./scripts/deploy-chaincode.sh` |
| `docker: permission denied` | Add your user to the `docker` group, log out/in |
| Backend: `Could not resolve placeholder 'MASTER_KEY'` | `source backend/.env.sh` in the same terminal |
| Backend: `No file found in ../fabric-samples/...` | Run it from the `backend/` folder, or set `FABRIC_CRYPTO_PATH` |
| `IPFS add failed` | `docker compose up -d`; check `curl -X POST http://127.0.0.1:5001/api/v0/id` |
| `MVCC_READ_CONFLICT` / "failed to commit" | Two transactions touched the same data in one block - just retry |
| "Challenge expired" at login | Click *Log in* again (challenges last 2 minutes) |
| "No private key for this DID in this browser" | Import the key backup file you downloaded at registration |
| Everything empty after `network.sh down` | Expected - the ledger is wiped. Redo steps 2-3 and re-register DIDs |
| Chaincode error `has no role yet` | An org admin must assign that DID a role |
| Dependency won't resolve (`fabric-gateway`) | Raise `fabric.gateway.version` in `backend/pom.xml` to the newest on Maven Central |

---

## 10. Suggested split of work

Chaincode + tests (`chaincode/`, `scripts/test-chaincode.sh`) · Backend (`backend/`) · Frontend (`frontend/`) ·
Report/diagrams (`docs/`). The chaincode API in section 6 is the contract between them.

---

## 11. CSD436 Course Mapping & Theory Report

For the complete theoretical mapping to **Prof. Sweta Mishra's CSD436 (Monsoon 2026)** lecture notes (including Execute-Order-Validate 7-step analysis, Cryptographic primitives, World State vs Block Store, and Viva Q&A), see:
- [CSD436 Project Report](file:///Users/shreegattani/my%20code/Blockchain/ResearchDataSharing/docs/CSD436_PROJECT_REPORT.md)

