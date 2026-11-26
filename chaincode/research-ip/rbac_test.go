package main

import (
	"strings"
	"testing"
)

// The permission matrix from the project document (README section 5).
func TestPermissionMatrix(t *testing.T) {
	cases := []struct {
		role, perm string
		want       bool
	}{
		// RESEARCHER: upload, read, verify, approve, transfer only inside own org
		{RoleResearcher, PermUpload, true},
		{RoleResearcher, PermRead, true},
		{RoleResearcher, PermVerify, true},
		{RoleResearcher, PermApprove, true},
		{RoleResearcher, PermTransferInOrg, true},
		{RoleResearcher, PermTransfer, false},
		{RoleResearcher, PermManage, false},
		{RoleResearcher, PermAudit, false},

		// COLLABORATOR: read and verify only
		{RoleCollab, PermRead, true},
		{RoleCollab, PermVerify, true},
		{RoleCollab, PermUpload, false},
		{RoleCollab, PermApprove, false},
		{RoleCollab, PermTransfer, false},

		// AUDITOR: read, verify, audit - never write or vote
		{RoleAuditor, PermRead, true},
		{RoleAuditor, PermAudit, true},
		{RoleAuditor, PermUpload, false},
		{RoleAuditor, PermApprove, false},

		// ORG_ADMIN manages roles but does not vote on updates
		{RoleOrgAdmin, PermManage, true},
		{RoleOrgAdmin, PermApprove, false},

		// PROJECT_LEAD may transfer anywhere and approve
		{RoleProjectLead, PermTransfer, true},
		{RoleProjectLead, PermApprove, true},
		{RoleProjectLead, PermManage, false},

		// unknown role has nothing
		{"HACKER", PermRead, false},
		{"", PermUpload, false},
	}
	for _, c := range cases {
		if got := hasPerm(c.role, c.perm); got != c.want {
			t.Errorf("hasPerm(%q, %q) = %v, want %v", c.role, c.perm, got, c.want)
		}
	}
}

func TestDIDFormat(t *testing.T) {
	valid := []string{"did:fabric:snu:alice", "did:fabric:network:gov", "did:fabric:iitd:carol.2"}
	invalid := []string{"alice", "did:other:snu:alice", "did:fabric:", "did:fabric:snu:al ice", "did:fabric:snu:a/../b", ""}
	for _, d := range valid {
		if !reDID.MatchString(d) {
			t.Errorf("%q should be a valid DID", d)
		}
	}
	for _, d := range invalid {
		if reDID.MatchString(d) {
			t.Errorf("%q should be rejected", d)
		}
	}
}

func TestAssetIDFormat(t *testing.T) {
	valid := []string{"DS-001", "dataset_1", "a.b-c", strings.Repeat("x", 64)}
	invalid := []string{"", "a b", "../etc", "a/b", strings.Repeat("x", 65)}
	for _, id := range valid {
		if !reID.MatchString(id) {
			t.Errorf("%q should be a valid id", id)
		}
	}
	for _, id := range invalid {
		if reID.MatchString(id) {
			t.Errorf("%q should be rejected", id)
		}
	}
}

func TestSha256Hex(t *testing.T) {
	// well-known SHA-256 test vector
	const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if got := sha256Hex("abc"); got != want {
		t.Errorf("sha256Hex(abc) = %s, want %s", got, want)
	}
	if len(sha256Hex("anything")) != 64 {
		t.Error("hash must be 64 hex characters")
	}
}
