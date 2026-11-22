package main

// DIDDoc: "Who are you?"  Only the PUBLIC key is stored. The private key stays with the user.
type DIDDoc struct {
	DID        string `json:"did"`
	PublicKey  string `json:"publicKey"`  // base64 X.509 SPKI (ECDSA P-256)
	PubKeyHash string `json:"pubKeyHash"` // sha256 hex of the public key
	Org        string `json:"org"`
	Active     bool   `json:"active"`
	Version    int    `json:"version"`
	CreatedAt  string `json:"createdAt"`
}

// Member: "What are you allowed to do?"  One org + department + role per DID.
type Member struct {
	DID    string `json:"did"`
	Org    string `json:"org"`
	Dept   string `json:"dept"`
	Role   string `json:"role"`
	Active bool   `json:"active"`
}

// Asset: the trusted record. The file itself is encrypted and lives on IPFS.
type Asset struct {
	AssetID        string `json:"assetId"`
	Name           string `json:"name"`
	OwnerDID       string `json:"ownerDid"`
	Org            string `json:"org"`
	Dept           string `json:"dept"`
	CID            string `json:"cid"`  // IPFS CID of the encrypted file
	Hash           string `json:"hash"` // SHA-256 (hex) of the ORIGINAL file
	Classification string `json:"classification"`
	Status         string `json:"status"` // ACTIVE | PENDING_UPDATE
	Version        int    `json:"version"`
	UpdatedAt      string `json:"updatedAt"`
}

// Proposal: a change to an asset that waits for department approval.
type Proposal struct {
	AssetID     string   `json:"assetId"`
	ProposerDID string   `json:"proposerDid"`
	NewCID      string   `json:"newCid"`
	NewHash     string   `json:"newHash"`
	BaseVersion int      `json:"baseVersion"`
	Nonce       int      `json:"nonce"`
	Required    int      `json:"required"`
	Approvals   []string `json:"approvals"`
	Deadline    string   `json:"deadline"`
	Open        bool     `json:"open"`
}

// LogEntry: one line of provenance / audit history.
type LogEntry struct {
	AssetID   string `json:"assetId"`
	Action    string `json:"action"`
	ActorDID  string `json:"actorDid"`
	Version   int    `json:"version"`
	TxID      string `json:"txId"`
	Timestamp string `json:"timestamp"`
}

type AccessResult struct {
	Asset         *Asset `json:"asset"`
	PendingUpdate bool   `json:"pendingUpdate"`
}

type VerifyResult struct {
	Valid          bool   `json:"valid"`
	RegisteredHash string `json:"registeredHash"`
	Version        int    `json:"version"`
}
