package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ResearchContract holds ALL chaincode functions. They are split over three files:
//   identity.go -> DID           ("Who are you?")
//   rbac.go     -> roles         ("What are you allowed to do?")
//   asset.go    -> research data ("Who owns it, what is its hash, what happened to it?")
type ResearchContract struct {
	contractapi.Contract
}

// CreateDID registers a DID with its PUBLIC key. Anyone can register, but a DID can do
// nothing until an organisation admin gives it a role.
func (c *ResearchContract) CreateDID(ctx Ctx, did, publicKey, org string) error {
	if !reDID.MatchString(did) {
		return fmt.Errorf("DID must look like did:fabric:<org>:<name>")
	}
	if !reID.MatchString(org) {
		return fmt.Errorf("invalid organisation name")
	}
	if strings.TrimSpace(publicKey) == "" {
		return fmt.Errorf("publicKey is required")
	}
	var existing DIDDoc
	ok, err := getState(ctx, "DID_"+did, &existing)
	if err != nil {
		return err
	}
	if ok {
		return fmt.Errorf("DID %s already exists", did)
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	return putState(ctx, "DID_"+did, DIDDoc{
		DID: did, PublicKey: publicKey, PubKeyHash: sha256Hex(publicKey),
		Org: org, Active: true, Version: 1, CreatedAt: now.Format(time.RFC3339),
	})
}

// GetDID returns the public DID document (used by the backend to verify signatures).
func (c *ResearchContract) GetDID(ctx Ctx, did string) (*DIDDoc, error) {
	var d DIDDoc
	ok, err := getState(ctx, "DID_"+did, &d)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("DID %s not found", did)
	}
	return &d, nil
}

// UpdatePublicKey rotates the verification key (lost / compromised key).
// The backend only calls this after the user proved ownership of the OLD key.
func (c *ResearchContract) UpdatePublicKey(ctx Ctx, callerDID, newPublicKey string, expectedVersion int) error {
	d, err := c.GetDID(ctx, callerDID)
	if err != nil {
		return err
	}
	if !d.Active {
		return fmt.Errorf("DID is not active")
	}
	if d.Version != expectedVersion {
		return fmt.Errorf("stale version: you saw v%d, current is v%d", expectedVersion, d.Version)
	}
	d.PublicKey = newPublicKey
	d.PubKeyHash = sha256Hex(newPublicKey)
	d.Version++
	return putState(ctx, "DID_"+callerDID, d)
}
