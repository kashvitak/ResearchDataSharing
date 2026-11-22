# Solidity reference (assignment only)

These three contracts are the Solidity version of the Fabric chaincode, written for the
CSD436 assignment. **Fabric does not run Solidity** - the real project logic is in
`chaincode/research-ip/` (Go). Function names map roughly 1:1:

| Solidity                    | Fabric chaincode (Go)                         |
|-----------------------------|-----------------------------------------------|
| `DIDRegistry.registerDID`   | `CreateDID`                                   |
| `DIDRegistry.rotateKey`     | `UpdatePublicKey`                             |
| `RBACManager.assignRole`    | `AssignRole`                                  |
| `ResearchAsset.registerAsset` | `RegisterAsset`                             |
| `proposeUpdate/approveUpdate/rejectUpdate/expireProposal` | same names             |
| `accessAsset / grantAccess / transferAsset / verifyIntegrity` | `AccessAsset / GrantAccess / TransferAsset / VerifyAsset` |
