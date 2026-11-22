package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

type Ctx = contractapi.TransactionContextInterface

const (
	StatusActive  = "ACTIVE"
	StatusPending = "PENDING_UPDATE"
	VotingWindow  = 72 * time.Hour
)

var (
	reID  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	reDID = regexp.MustCompile(`^did:fabric:[A-Za-z0-9._:-]{1,100}$`)
)

func getState(ctx Ctx, key string, out interface{}) (bool, error) {
	b, err := ctx.GetStub().GetState(key)
	if err != nil {
		return false, err
	}
	if b == nil {
		return false, nil
	}
	return true, json.Unmarshal(b, out)
}

func putState(ctx Ctx, key string, v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return ctx.GetStub().PutState(key, b)
}

// txTime is the transaction timestamp (identical on every peer, so it is deterministic).
func txTime(ctx Ctx) (time.Time, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return time.Time{}, err
	}
	return time.Unix(ts.Seconds, int64(ts.Nanos)).UTC(), nil
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// writeLog appends one provenance entry. Every entry has its own key, so logging
// never causes read/write conflicts between users.
func writeLog(ctx Ctx, assetID, action, actor string, version int) error {
	t, err := txTime(ctx)
	if err != nil {
		return err
	}
	txid := ctx.GetStub().GetTxID()
	key, err := ctx.GetStub().CreateCompositeKey("LOG", []string{assetID, fmt.Sprintf("%020d", t.UnixNano()), txid})
	if err != nil {
		return err
	}
	return putState(ctx, key, LogEntry{
		AssetID: assetID, Action: action, ActorDID: actor, Version: version,
		TxID: txid, Timestamp: t.Format(time.RFC3339),
	})
}

func loadAsset(ctx Ctx, assetID string) (*Asset, error) {
	var a Asset
	ok, err := getState(ctx, "ASSET_"+assetID, &a)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("asset %s does not exist", assetID)
	}
	return &a, nil
}

func jsonUnmarshal(b []byte, v interface{}) error { return json.Unmarshal(b, v) }
