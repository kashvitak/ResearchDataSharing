package main

import (
	"fmt"
	"time"
)

// ---------------------------------------------------------------- read rules

// canRead: same org+department, an explicit grant from the owner, or an AUDITOR.
func canRead(ctx Ctx, m *Member, a *Asset) (bool, error) {
	if m.Role == RoleAuditor {
		return true, nil
	}
	if m.Org == a.Org && m.Dept == a.Dept {
		return true, nil
	}
	g, err := ctx.GetStub().GetState("GRANT_" + a.AssetID + "_" + m.DID)
	return g != nil, err
}

func requireSameDept(m *Member, a *Asset) error {
	if m.Org != a.Org || m.Dept != a.Dept {
		return fmt.Errorf("only members of %s/%s may do this", a.Org, a.Dept)
	}
	return nil
}

// ------------------------------------------------------------------ register

// RegisterAsset records a new research asset. The file is already encrypted and on IPFS.
func (c *ResearchContract) RegisterAsset(ctx Ctx, callerDID, assetID, name, cid, hash, classification string) error {
	m, err := requirePerm(ctx, callerDID, PermUpload)
	if err != nil {
		return err
	}
	if !reID.MatchString(assetID) {
		return fmt.Errorf("assetId may only contain letters, digits, . _ - (max 64)")
	}
	switch classification {
	case "PUBLIC", "INTERNAL", "CONFIDENTIAL":
	default:
		return fmt.Errorf("classification must be PUBLIC, INTERNAL or CONFIDENTIAL")
	}
	if cid == "" || len(hash) != 64 {
		return fmt.Errorf("cid and a 64-char SHA-256 hex hash are required")
	}
	var existing Asset
	ok, err := getState(ctx, "ASSET_"+assetID, &existing)
	if err != nil {
		return err
	}
	if ok {
		return fmt.Errorf("asset %s already exists", assetID)
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	a := Asset{
		AssetID: assetID, Name: name, OwnerDID: callerDID, Org: m.Org, Dept: m.Dept,
		CID: cid, Hash: hash, Classification: classification,
		Status: StatusActive, Version: 1, UpdatedAt: now.Format(time.RFC3339),
	}
	if err := putState(ctx, "ASSET_"+assetID, a); err != nil {
		return err
	}
	return writeLog(ctx, assetID, "REGISTER", callerDID, 1)
}

// --------------------------------------------------------------------- reads

// GetAsset returns metadata (no logging).
func (c *ResearchContract) GetAsset(ctx Ctx, callerDID, assetID string) (*Asset, error) {
	m, err := requirePerm(ctx, callerDID, PermRead)
	if err != nil {
		return nil, err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return nil, err
	}
	if ok, err := canRead(ctx, m, a); err != nil {
		return nil, err
	} else if !ok {
		return nil, fmt.Errorf("access denied: ask the owner to grant you access")
	}
	return a, nil
}

// ListAssets returns every asset the caller is allowed to read.
func (c *ResearchContract) ListAssets(ctx Ctx, callerDID string) ([]*Asset, error) {
	m, err := requirePerm(ctx, callerDID, PermRead)
	if err != nil {
		return nil, err
	}
	it, err := ctx.GetStub().GetStateByRange("ASSET_", "ASSET_~")
	if err != nil {
		return nil, err
	}
	defer it.Close()
	out := []*Asset{}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, err
		}
		var a Asset
		if err := jsonUnmarshal(kv.Value, &a); err != nil {
			return nil, err
		}
		if ok, err := canRead(ctx, m, &a); err != nil {
			return nil, err
		} else if ok {
			out = append(out, &a)
		}
	}
	return out, nil
}

// AccessAsset is a LOGGED read. It always returns the last COMMITTED version, even while
// an update is being voted on, so readers never see half-approved data.
func (c *ResearchContract) AccessAsset(ctx Ctx, callerDID, assetID string) (*AccessResult, error) {
	a, err := c.GetAsset(ctx, callerDID, assetID)
	if err != nil {
		return nil, err
	}
	if err := writeLog(ctx, assetID, "ACCESS", callerDID, a.Version); err != nil {
		return nil, err
	}
	return &AccessResult{Asset: a, PendingUpdate: a.Status == StatusPending}, nil
}

// GetProposal lets department approvers see (and download) the proposed new file.
func (c *ResearchContract) GetProposal(ctx Ctx, callerDID, assetID string) (*Proposal, error) {
	m, err := requirePerm(ctx, callerDID, PermApprove)
	if err != nil {
		return nil, err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return nil, err
	}
	if err := requireSameDept(m, a); err != nil {
		return nil, err
	}
	var p Proposal
	ok, err := getState(ctx, "PROP_"+assetID, &p)
	if err != nil {
		return nil, err
	}
	if !ok || !p.Open {
		return nil, fmt.Errorf("no open proposal for %s", assetID)
	}
	return &p, nil
}

// VerifyAsset compares a hash (of a file you hold) with the registered hash.
func (c *ResearchContract) VerifyAsset(ctx Ctx, callerDID, assetID, hash string) (*VerifyResult, error) {
	if _, err := requirePerm(ctx, callerDID, PermVerify); err != nil {
		return nil, err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return nil, err
	}
	return &VerifyResult{Valid: a.Hash == hash, RegisteredHash: a.Hash, Version: a.Version}, nil
}

// GetAssetHistory returns the full provenance trail, oldest first.
func (c *ResearchContract) GetAssetHistory(ctx Ctx, callerDID, assetID string) ([]*LogEntry, error) {
	if _, err := c.GetAsset(ctx, callerDID, assetID); err != nil {
		return nil, err
	}
	it, err := ctx.GetStub().GetStateByPartialCompositeKey("LOG", []string{assetID})
	if err != nil {
		return nil, err
	}
	defer it.Close()
	out := []*LogEntry{}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, err
		}
		var e LogEntry
		if err := jsonUnmarshal(kv.Value, &e); err != nil {
			return nil, err
		}
		out = append(out, &e)
	}
	return out, nil
}

// ------------------------------------------------- peer-verified updates (voting)

// ProposeUpdate starts a change. The asset is LOCKED (PENDING_UPDATE) until the vote ends.
//   expectedVersion = the version the proposer saw. If someone else changed the asset in
//   the meantime the call fails instead of silently overwriting their work.
func (c *ResearchContract) ProposeUpdate(ctx Ctx, callerDID, assetID, newCID, newHash string, expectedVersion int) error {
	m, err := requirePerm(ctx, callerDID, PermUpload)
	if err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	if err := requireSameDept(m, a); err != nil {
		return err
	}
	var prev Proposal
	if _, err := getState(ctx, "PROP_"+assetID, &prev); err != nil {
		return err
	}
	if a.Status == StatusPending {
		return fmt.Errorf("asset is locked by proposal #%d from %s - wait for the vote to finish", prev.Nonce, prev.ProposerDID)
	}
	if a.Version != expectedVersion {
		return fmt.Errorf("stale version: you saw v%d but the asset is now v%d - reload and retry", expectedVersion, a.Version)
	}
	if newCID == "" || len(newHash) != 64 {
		return fmt.Errorf("newCid and a 64-char SHA-256 hex hash are required")
	}
	// How many OTHER approvers must agree? The number is frozen now.
	required, err := countApprovers(ctx, a.Org, a.Dept)
	if err != nil {
		return err
	}
	if hasPerm(m.Role, PermApprove) && required > 0 {
		required-- // the proposer counts as a "yes"
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	p := Proposal{
		AssetID: assetID, ProposerDID: callerDID, NewCID: newCID, NewHash: newHash,
		BaseVersion: expectedVersion, Nonce: prev.Nonce + 1, Required: required,
		Approvals: []string{}, Deadline: now.Add(VotingWindow).Format(time.RFC3339), Open: true,
	}
	a.Status = StatusPending
	if err := writeLog(ctx, assetID, "PROPOSE", callerDID, a.Version); err != nil {
		return err
	}
	if required == 0 { // nobody else has to approve
		return commitProposal(ctx, a, &p, now)
	}
	if err := putState(ctx, "ASSET_"+assetID, a); err != nil {
		return err
	}
	return putState(ctx, "PROP_"+assetID, p)
}

func loadOpenProposal(ctx Ctx, assetID string, nonce int, now time.Time) (*Proposal, error) {
	var p Proposal
	ok, err := getState(ctx, "PROP_"+assetID, &p)
	if err != nil {
		return nil, err
	}
	if !ok || !p.Open {
		return nil, fmt.Errorf("no open proposal for %s", assetID)
	}
	if p.Nonce != nonce {
		return nil, fmt.Errorf("this is proposal #%d, not #%d", p.Nonce, nonce)
	}
	dl, err := time.Parse(time.RFC3339, p.Deadline)
	if err != nil {
		return nil, err
	}
	if now.After(dl) {
		return nil, fmt.Errorf("voting window is over - call ExpireProposal to unlock the asset")
	}
	return &p, nil
}

func commitProposal(ctx Ctx, a *Asset, p *Proposal, now time.Time) error {
	if a.Version != p.BaseVersion {
		return fmt.Errorf("stale version at commit time")
	}
	a.CID = p.NewCID
	a.Hash = p.NewHash
	a.Version++
	a.UpdatedAt = now.Format(time.RFC3339)
	a.Status = StatusActive
	p.Open = false
	if err := putState(ctx, "ASSET_"+a.AssetID, a); err != nil {
		return err
	}
	if err := putState(ctx, "PROP_"+a.AssetID, p); err != nil {
		return err
	}
	return writeLog(ctx, a.AssetID, "UPDATE", p.ProposerDID, a.Version)
}

// ApproveUpdate: a department peer verified the new file and signs off.
// The LAST required approval commits the change.
func (c *ResearchContract) ApproveUpdate(ctx Ctx, callerDID, assetID string, nonce int) error {
	m, err := requirePerm(ctx, callerDID, PermApprove)
	if err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	if err := requireSameDept(m, a); err != nil {
		return err
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	p, err := loadOpenProposal(ctx, assetID, nonce, now)
	if err != nil {
		return err
	}
	if callerDID == p.ProposerDID {
		return fmt.Errorf("the proposer cannot approve their own change")
	}
	for _, v := range p.Approvals {
		if v == callerDID {
			return fmt.Errorf("you already approved this proposal")
		}
	}
	p.Approvals = append(p.Approvals, callerDID)
	if err := writeLog(ctx, assetID, "APPROVE", callerDID, a.Version); err != nil {
		return err
	}
	if len(p.Approvals) >= p.Required {
		return commitProposal(ctx, a, p, now)
	}
	return putState(ctx, "PROP_"+assetID, p)
}

// RejectUpdate: one "no" from any approver (or the proposer withdrawing) cancels the proposal.
func (c *ResearchContract) RejectUpdate(ctx Ctx, callerDID, assetID string, nonce int, reason string) error {
	m, err := loadActiveMember(ctx, callerDID)
	if err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	if err := requireSameDept(m, a); err != nil {
		return err
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	p, err := loadOpenProposal(ctx, assetID, nonce, now)
	if err != nil {
		return err
	}
	if callerDID != p.ProposerDID && !hasPerm(m.Role, PermApprove) {
		return fmt.Errorf("only the proposer or a department approver can reject")
	}
	p.Open = false
	a.Status = StatusActive
	if err := putState(ctx, "ASSET_"+assetID, a); err != nil {
		return err
	}
	if err := putState(ctx, "PROP_"+assetID, p); err != nil {
		return err
	}
	return writeLog(ctx, assetID, "REJECT", callerDID, a.Version)
}

// ExpireProposal: anyone can release a lock whose voting window has passed (no deadlocks).
func (c *ResearchContract) ExpireProposal(ctx Ctx, callerDID, assetID string) error {
	if _, err := loadActiveMember(ctx, callerDID); err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	var p Proposal
	ok, err := getState(ctx, "PROP_"+assetID, &p)
	if err != nil {
		return err
	}
	if !ok || !p.Open {
		return fmt.Errorf("no open proposal for %s", assetID)
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	dl, err := time.Parse(time.RFC3339, p.Deadline)
	if err != nil {
		return err
	}
	if !now.After(dl) {
		return fmt.Errorf("voting window is still open until %s", p.Deadline)
	}
	p.Open = false
	a.Status = StatusActive
	if err := putState(ctx, "ASSET_"+assetID, a); err != nil {
		return err
	}
	if err := putState(ctx, "PROP_"+assetID, p); err != nil {
		return err
	}
	return writeLog(ctx, assetID, "EXPIRE", callerDID, a.Version)
}

// ------------------------------------------------------- sharing and ownership

// GrantAccess: the owner lets a researcher from ANOTHER department / university read the asset.
func (c *ResearchContract) GrantAccess(ctx Ctx, callerDID, assetID, granteeDID string) error {
	if _, err := loadActiveMember(ctx, callerDID); err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	if a.OwnerDID != callerDID {
		return fmt.Errorf("only the owner can grant access")
	}
	if _, err := requirePerm(ctx, granteeDID, PermRead); err != nil {
		return err
	}
	if err := ctx.GetStub().PutState("GRANT_"+assetID+"_"+granteeDID, []byte("1")); err != nil {
		return err
	}
	return writeLog(ctx, assetID, "GRANT:"+granteeDID, callerDID, a.Version)
}

// TransferAsset hands ownership to another member (e.g. university -> industry partner).
// TRANSFER (project lead / admin): anywhere.  TRANSFER_IN_ORG (researcher): only inside own org.
func (c *ResearchContract) TransferAsset(ctx Ctx, callerDID, assetID, newOwnerDID string, expectedVersion int) error {
	m, err := loadActiveMember(ctx, callerDID)
	if err != nil {
		return err
	}
	a, err := loadAsset(ctx, assetID)
	if err != nil {
		return err
	}
	if a.OwnerDID != callerDID {
		return fmt.Errorf("only the owner can transfer the asset")
	}
	if a.Status == StatusPending {
		return fmt.Errorf("asset is locked by an open update proposal")
	}
	if a.Version != expectedVersion {
		return fmt.Errorf("stale version: you saw v%d but the asset is now v%d", expectedVersion, a.Version)
	}
	target, err := loadActiveMember(ctx, newOwnerDID)
	if err != nil {
		return err
	}
	full := hasPerm(m.Role, PermTransfer)
	inOrg := hasPerm(m.Role, PermTransferInOrg) && target.Org == a.Org
	if !full && !inOrg {
		return fmt.Errorf("access denied: your role may only transfer inside your own organisation")
	}
	now, err := txTime(ctx)
	if err != nil {
		return err
	}
	a.OwnerDID, a.Org, a.Dept = newOwnerDID, target.Org, target.Dept
	a.Version++
	a.UpdatedAt = now.Format(time.RFC3339)
	if err := putState(ctx, "ASSET_"+assetID, a); err != nil {
		return err
	}
	return writeLog(ctx, assetID, "TRANSFER:"+newOwnerDID, callerDID, a.Version)
}
