package main

import (
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	"github.com/hyperledger/fabric-protos-go/ledger/queryresult"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// ---------------------------------------------------------------------------
// A tiny in-memory ledger so the chaincode rules can be tested without Docker.
// Only the stub methods the chaincode actually calls are implemented.
// ---------------------------------------------------------------------------

type fakeStub struct {
	shim.ChaincodeStubInterface // anything not overridden below would panic (not used)
	state                       map[string][]byte
	txID                        string
	ts                          time.Time
	n                           int
}

func (s *fakeStub) GetState(k string) ([]byte, error) {
	v, found := s.state[k]
	if !found {
		return nil, nil
	}
	return v, nil
}
func (s *fakeStub) PutState(k string, v []byte) error { s.state[k] = v; return nil }
func (s *fakeStub) DelState(k string) error           { delete(s.state, k); return nil }
func (s *fakeStub) GetTxID() string                   { return s.txID }
func (s *fakeStub) GetTxTimestamp() (*timestamppb.Timestamp, error) {
	return timestamppb.New(s.ts), nil
}
func (s *fakeStub) CreateCompositeKey(objectType string, attrs []string) (string, error) {
	return "\x00" + objectType + "\x00" + strings.Join(attrs, "\x00") + "\x00", nil
}

func (s *fakeStub) scan(match func(k string) bool) *fakeIter {
	keys := []string{}
	for k := range s.state {
		if match(k) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	it := &fakeIter{}
	for _, k := range keys {
		it.items = append(it.items, &queryresult.KV{Key: k, Value: s.state[k]})
	}
	return it
}

func (s *fakeStub) GetStateByPartialCompositeKey(objectType string, attrs []string) (shim.StateQueryIteratorInterface, error) {
	prefix := "\x00" + objectType + "\x00"
	for _, a := range attrs {
		prefix += a + "\x00"
	}
	return s.scan(func(k string) bool { return strings.HasPrefix(k, prefix) }), nil
}

func (s *fakeStub) GetStateByRange(start, end string) (shim.StateQueryIteratorInterface, error) {
	return s.scan(func(k string) bool { return k >= start && k < end }), nil
}

type fakeIter struct {
	items []*queryresult.KV
	i     int
}

func (it *fakeIter) HasNext() bool { return it.i < len(it.items) }
func (it *fakeIter) Close() error  { return nil }
func (it *fakeIter) Next() (*queryresult.KV, error) {
	kv := it.items[it.i]
	it.i++
	return kv, nil
}

type fakeCtx struct {
	contractapi.TransactionContextInterface
	stub *fakeStub
}

func (c *fakeCtx) GetStub() shim.ChaincodeStubInterface { return c.stub }

// tx starts a new transaction: new id and a timestamp one second later.
func (c *fakeCtx) tx() *fakeCtx {
	c.stub.n++
	c.stub.txID = fmt.Sprintf("tx%04d", c.stub.n)
	c.stub.ts = c.stub.ts.Add(time.Second)
	return c
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const (
	gov       = "did:fabric:network:gov"
	snuAdmin  = "did:fabric:snu:admin"
	iitdAdmin = "did:fabric:iitd:admin"
	alice     = "did:fabric:snu:alice"
	bob       = "did:fabric:snu:bob"
	dave      = "did:fabric:snu:dave"
	carol     = "did:fabric:iitd:carol"
)

var (
	h1 = strings.Repeat("a", 64)
	h2 = strings.Repeat("b", 64)
)

func ok(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func fails(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error containing %q, but the call succeeded", want)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("expected an error containing %q, got %q", want, err.Error())
	}
}

// newWorld: governance, two organisations, alice+bob (SNU/CSE researchers), carol (IITD/ECE collaborator).
// With withDave a third SNU/CSE researcher exists, so a proposal needs 2 other approvals.
func newWorld(t *testing.T, withDave bool) (*ResearchContract, *fakeCtx) {
	t.Helper()
	cc := &ResearchContract{}
	ctx := &fakeCtx{stub: &fakeStub{
		state: map[string][]byte{},
		ts:    time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC),
	}}
	for _, d := range []struct{ did, org string }{
		{gov, "network"}, {snuAdmin, "snu"}, {iitdAdmin, "iitd"},
		{alice, "snu"}, {bob, "snu"}, {dave, "snu"}, {carol, "iitd"},
	} {
		ok(t, cc.CreateDID(ctx.tx(), d.did, "pub-"+d.did, d.org))
	}
	ok(t, cc.InitNetwork(ctx.tx(), gov))
	ok(t, cc.AddOrganization(ctx.tx(), gov, "snu", snuAdmin))
	ok(t, cc.AddOrganization(ctx.tx(), gov, "iitd", iitdAdmin))
	ok(t, cc.AssignRole(ctx.tx(), snuAdmin, alice, "CSE", RoleResearcher))
	ok(t, cc.AssignRole(ctx.tx(), snuAdmin, bob, "CSE", RoleResearcher))
	if withDave {
		ok(t, cc.AssignRole(ctx.tx(), snuAdmin, dave, "CSE", RoleResearcher))
	}
	ok(t, cc.AssignRole(ctx.tx(), iitdAdmin, carol, "ECE", RoleCollab))
	return cc, ctx
}

func registerDS1(t *testing.T, cc *ResearchContract, ctx *fakeCtx) {
	t.Helper()
	ok(t, cc.RegisterAsset(ctx.tx(), alice, "DS-1", "data.csv", "QmOld", h1, "CONFIDENTIAL"))
}

func mustGet(t *testing.T, cc *ResearchContract, ctx *fakeCtx, who string) *Asset {
	t.Helper()
	a, err := cc.GetAsset(ctx.tx(), who, "DS-1")
	ok(t, err)
	return a
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

func TestGovernanceAndRoleRules(t *testing.T) {
	cc, ctx := newWorld(t, false)
	fails(t, cc.CreateDID(ctx.tx(), alice, "k", "snu"), "already exists")
	fails(t, cc.InitNetwork(ctx.tx(), gov), "already initialised")
	fails(t, cc.AddOrganization(ctx.tx(), alice, "evil", alice), "only the network governance")
	fails(t, cc.AssignRole(ctx.tx(), alice, bob, "CSE", RoleAuditor), "access denied") // researchers cannot manage roles
	fails(t, cc.AssignRole(ctx.tx(), snuAdmin, bob, "CSE", RoleOrgAdmin), "role must be one of")
	fails(t, cc.AssignRole(ctx.tx(), snuAdmin, carol, "CSE", RoleResearcher), "another organisation")
}

func TestRegisterAssetRules(t *testing.T) {
	cc, ctx := newWorld(t, false)
	fails(t, cc.RegisterAsset(ctx.tx(), carol, "DS-1", "x", "QmA", h1, "CONFIDENTIAL"), "access denied") // collaborator cannot upload
	fails(t, cc.RegisterAsset(ctx.tx(), alice, "DS-1", "x", "QmA", h1, "SECRET"), "classification")
	fails(t, cc.RegisterAsset(ctx.tx(), alice, "DS-1", "x", "QmA", "short", "CONFIDENTIAL"), "64-char")
	registerDS1(t, cc, ctx)
	fails(t, cc.RegisterAsset(ctx.tx(), alice, "DS-1", "x", "QmA", h1, "CONFIDENTIAL"), "already exists")
	a := mustGet(t, cc, ctx, alice)
	if a.Version != 1 || a.Status != StatusActive || a.OwnerDID != alice {
		t.Fatalf("unexpected new asset: %+v", a)
	}
}

func TestProposalLocksThenCommitsAsVersion2(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)

	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	a := mustGet(t, cc, ctx, bob)
	if a.Status != StatusPending || a.Version != 1 || a.CID != "QmOld" {
		t.Fatalf("while voting the asset must be locked and still show the old data, got %+v", a)
	}

	ok(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1))
	a = mustGet(t, cc, ctx, bob)
	if a.Status != StatusActive || a.Version != 2 || a.CID != "QmNew" || a.Hash != h2 {
		t.Fatalf("after the approval the asset must be v2 with the new data, got %+v", a)
	}
}

func TestAllRequiredApproversMustVote(t *testing.T) {
	cc, ctx := newWorld(t, true) // alice proposes -> bob AND dave must approve
	registerDS1(t, cc, ctx)
	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))

	fails(t, cc.ApproveUpdate(ctx.tx(), alice, "DS-1", 1), "cannot approve their own")
	ok(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1))
	if a := mustGet(t, cc, ctx, bob); a.Version != 1 || a.Status != StatusPending {
		t.Fatalf("one of two approvals must not commit, got %+v", a)
	}
	fails(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1), "already approved")
	ok(t, cc.ApproveUpdate(ctx.tx(), dave, "DS-1", 1))
	if a := mustGet(t, cc, ctx, bob); a.Version != 2 || a.Status != StatusActive {
		t.Fatalf("both approvals must commit v2, got %+v", a)
	}
}

func TestNonApproverCannotVote(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)
	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	fails(t, cc.ApproveUpdate(ctx.tx(), carol, "DS-1", 1), "access denied") // collaborator, other university
	if a := mustGet(t, cc, ctx, alice); a.Version != 1 {
		t.Fatalf("a rejected vote must not change the asset, got %+v", a)
	}
}

func TestStaleVersionAndLockedAssetAreRejected(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)
	fails(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 7), "stale version")

	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	fails(t, cc.ProposeUpdate(ctx.tx(), bob, "DS-1", "QmOther", h2, 1), "locked")
	fails(t, cc.TransferAsset(ctx.tx(), alice, "DS-1", bob, 1), "locked")
}

func TestRejectUnlocksTheAsset(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)
	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	ok(t, cc.RejectUpdate(ctx.tx(), bob, "DS-1", 1, "wrong file"))
	a := mustGet(t, cc, ctx, bob)
	if a.Status != StatusActive || a.Version != 1 || a.CID != "QmOld" {
		t.Fatalf("a rejected proposal must leave the asset unchanged and unlocked, got %+v", a)
	}
	fails(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1), "no open proposal")
}

func TestExpiredLockCanBeReleased(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)
	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	fails(t, cc.ExpireProposal(ctx.tx(), bob, "DS-1"), "still open")

	ctx.stub.ts = ctx.stub.ts.Add(73 * time.Hour) // voting window is 72 hours
	fails(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1), "voting window is over")
	ok(t, cc.ExpireProposal(ctx.tx(), bob, "DS-1"))
	if a := mustGet(t, cc, ctx, alice); a.Status != StatusActive || a.Version != 1 {
		t.Fatalf("an expired proposal must unlock the asset, got %+v", a)
	}
}

// Regression test: the final approval writes APPROVE and UPDATE in the same transaction.
// Both must survive in the audit trail.
func TestProvenanceKeepsApproveAndUpdate(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)
	ok(t, cc.ProposeUpdate(ctx.tx(), alice, "DS-1", "QmNew", h2, 1))
	ok(t, cc.ApproveUpdate(ctx.tx(), bob, "DS-1", 1))

	history, err := cc.GetAssetHistory(ctx.tx(), alice, "DS-1")
	ok(t, err)
	seen := map[string]bool{}
	for _, e := range history {
		seen[e.Action] = true
	}
	for _, want := range []string{"REGISTER", "PROPOSE", "APPROVE", "UPDATE"} {
		if !seen[want] {
			t.Errorf("history is missing %s (got %v)", want, seen)
		}
	}
}

func TestCrossUniversityAccessNeedsGrant(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)

	_, err := cc.GetAsset(ctx.tx(), carol, "DS-1")
	fails(t, err, "access denied")
	fails(t, cc.GrantAccess(ctx.tx(), bob, "DS-1", carol), "only the owner")

	ok(t, cc.GrantAccess(ctx.tx(), alice, "DS-1", carol))
	a := mustGet(t, cc, ctx, carol)
	if a.AssetID != "DS-1" {
		t.Fatalf("carol should now read DS-1, got %+v", a)
	}
}

func TestTransferRules(t *testing.T) {
	cc, ctx := newWorld(t, false)
	registerDS1(t, cc, ctx)

	// a researcher may only transfer inside their own organisation
	fails(t, cc.TransferAsset(ctx.tx(), alice, "DS-1", carol, 1), "access denied")
	fails(t, cc.TransferAsset(ctx.tx(), bob, "DS-1", alice, 1), "only the owner")
	fails(t, cc.TransferAsset(ctx.tx(), alice, "DS-1", bob, 9), "stale version")

	ok(t, cc.TransferAsset(ctx.tx(), alice, "DS-1", bob, 1))
	a := mustGet(t, cc, ctx, bob)
	if a.OwnerDID != bob || a.Version != 2 {
		t.Fatalf("ownership should have moved to bob at v2, got %+v", a)
	}
}
