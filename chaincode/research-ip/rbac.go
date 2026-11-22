package main

import (
	"fmt"
)

const (
	PermUpload        = "UPLOAD"
	PermRead          = "READ"
	PermTransfer      = "TRANSFER"
	PermTransferInOrg = "TRANSFER_IN_ORG" // the "Limited" transfer of the Researcher role
	PermVerify        = "VERIFY"
	PermAudit         = "AUDIT"
	PermApprove       = "APPROVE" // may vote on department updates
	PermManage        = "MANAGE"  // may assign / remove roles in own organisation

	RoleOrgAdmin    = "ORG_ADMIN"
	RoleProjectLead = "PROJECT_LEAD"
	RoleResearcher  = "RESEARCHER"
	RoleCollab      = "COLLABORATOR"
	RoleAuditor     = "AUDITOR"
)

// The permission matrix from the project document. Edit here to change who can do what.
var rolePerms = map[string][]string{
	RoleOrgAdmin:    {PermUpload, PermRead, PermTransfer, PermVerify, PermAudit, PermManage},
	RoleProjectLead: {PermUpload, PermRead, PermTransfer, PermVerify, PermAudit, PermApprove},
	RoleResearcher:  {PermUpload, PermRead, PermVerify, PermApprove, PermTransferInOrg},
	RoleCollab:      {PermRead, PermVerify},
	RoleAuditor:     {PermRead, PermVerify, PermAudit},
}

func hasPerm(role, perm string) bool {
	for _, p := range rolePerms[role] {
		if p == perm {
			return true
		}
	}
	return false
}

// loadActiveMember: the DID must be active AND hold an active role.
func loadActiveMember(ctx Ctx, did string) (*Member, error) {
	var d DIDDoc
	ok, err := getState(ctx, "DID_"+did, &d)
	if err != nil {
		return nil, err
	}
	if !ok || !d.Active {
		return nil, fmt.Errorf("DID %s is not registered or not active", did)
	}
	var m Member
	ok, err = getState(ctx, "MEMBER_"+did, &m)
	if err != nil {
		return nil, err
	}
	if !ok || !m.Active {
		return nil, fmt.Errorf("%s has no role yet - ask your organisation admin", did)
	}
	return &m, nil
}

// requirePerm is the one check every protected function starts with.
func requirePerm(ctx Ctx, did, perm string) (*Member, error) {
	m, err := loadActiveMember(ctx, did)
	if err != nil {
		return nil, err
	}
	if !hasPerm(m.Role, perm) {
		return nil, fmt.Errorf("access denied: role %s cannot %s", m.Role, perm)
	}
	return m, nil
}

// countApprovers = number of active members of a department whose role can APPROVE.
func countApprovers(ctx Ctx, org, dept string) (int, error) {
	it, err := ctx.GetStub().GetStateByPartialCompositeKey("DEPT", []string{org, dept})
	if err != nil {
		return 0, err
	}
	defer it.Close()
	n := 0
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return 0, err
		}
		if hasPerm(string(kv.Value), PermApprove) {
			n++
		}
	}
	return n, nil
}

func deptKey(ctx Ctx, org, dept, did string) (string, error) {
	return ctx.GetStub().CreateCompositeKey("DEPT", []string{org, dept, did})
}

// InitNetwork is run ONCE after deployment: it names the network governance DID.
func (c *ResearchContract) InitNetwork(ctx Ctx, governanceDID string) error {
	if g, err := ctx.GetStub().GetState("GOVERNANCE"); err != nil {
		return err
	} else if g != nil {
		return fmt.Errorf("network already initialised")
	}
	d, err := c.GetDID(ctx, governanceDID)
	if err != nil {
		return err
	}
	if !d.Active {
		return fmt.Errorf("governance DID is not active")
	}
	return ctx.GetStub().PutState("GOVERNANCE", []byte(governanceDID))
}

// AddOrganization: governance onboards a university / lab / company and names its admin.
func (c *ResearchContract) AddOrganization(ctx Ctx, callerDID, org, adminDID string) error {
	gov, err := ctx.GetStub().GetState("GOVERNANCE")
	if err != nil {
		return err
	}
	if gov == nil || string(gov) != callerDID {
		return fmt.Errorf("only the network governance can add organisations")
	}
	if !reID.MatchString(org) {
		return fmt.Errorf("invalid organisation name")
	}
	if existing, err := ctx.GetStub().GetState("ORG_" + org); err != nil {
		return err
	} else if existing != nil {
		return fmt.Errorf("organisation %s already exists", org)
	}
	d, err := c.GetDID(ctx, adminDID)
	if err != nil {
		return err
	}
	if !d.Active {
		return fmt.Errorf("admin DID is not active")
	}
	if err := ctx.GetStub().PutState("ORG_"+org, []byte(adminDID)); err != nil {
		return err
	}
	return putState(ctx, "MEMBER_"+adminDID, Member{DID: adminDID, Org: org, Dept: "ADMIN", Role: RoleOrgAdmin, Active: true})
}

// AssignRole: an org admin gives a role + department to a user of THEIR OWN organisation.
func (c *ResearchContract) AssignRole(ctx Ctx, callerDID, targetDID, dept, role string) error {
	admin, err := requirePerm(ctx, callerDID, PermManage)
	if err != nil {
		return err
	}
	if _, ok := rolePerms[role]; !ok || role == RoleOrgAdmin {
		return fmt.Errorf("role must be one of PROJECT_LEAD, RESEARCHER, COLLABORATOR, AUDITOR")
	}
	if !reID.MatchString(dept) {
		return fmt.Errorf("invalid department name")
	}
	d, err := c.GetDID(ctx, targetDID)
	if err != nil {
		return err
	}
	if !d.Active {
		return fmt.Errorf("target DID is not active")
	}
	var old Member
	exists, err := getState(ctx, "MEMBER_"+targetDID, &old)
	if err != nil {
		return err
	}
	if exists && old.Active {
		if old.Org != admin.Org {
			return fmt.Errorf("user belongs to another organisation")
		}
		if old.Role == RoleOrgAdmin {
			return fmt.Errorf("cannot change an organisation admin")
		}
		k, err := deptKey(ctx, old.Org, old.Dept, old.DID)
		if err != nil {
			return err
		}
		if err := ctx.GetStub().DelState(k); err != nil {
			return err
		}
	}
	m := Member{DID: targetDID, Org: admin.Org, Dept: dept, Role: role, Active: true}
	if err := putState(ctx, "MEMBER_"+targetDID, m); err != nil {
		return err
	}
	k, err := deptKey(ctx, m.Org, m.Dept, m.DID)
	if err != nil {
		return err
	}
	return ctx.GetStub().PutState(k, []byte(role))
}

// RemoveRole: an org admin revokes a user of their own organisation.
func (c *ResearchContract) RemoveRole(ctx Ctx, callerDID, targetDID string) error {
	admin, err := requirePerm(ctx, callerDID, PermManage)
	if err != nil {
		return err
	}
	var m Member
	ok, err := getState(ctx, "MEMBER_"+targetDID, &m)
	if err != nil {
		return err
	}
	if !ok || !m.Active {
		return fmt.Errorf("user has no active role")
	}
	if m.Org != admin.Org {
		return fmt.Errorf("user belongs to another organisation")
	}
	if m.Role == RoleOrgAdmin {
		return fmt.Errorf("cannot remove an organisation admin")
	}
	k, err := deptKey(ctx, m.Org, m.Dept, m.DID)
	if err != nil {
		return err
	}
	if err := ctx.GetStub().DelState(k); err != nil {
		return err
	}
	m.Active = false
	return putState(ctx, "MEMBER_"+targetDID, m)
}

// CheckPermission is a read-only helper for the backend / UI.
func (c *ResearchContract) CheckPermission(ctx Ctx, did, perm string) (bool, error) {
	m, err := loadActiveMember(ctx, did)
	if err != nil {
		return false, nil
	}
	return hasPerm(m.Role, perm), nil
}

// GetMember returns the caller's org, department and role.
func (c *ResearchContract) GetMember(ctx Ctx, did string) (*Member, error) {
	var m Member
	ok, err := getState(ctx, "MEMBER_"+did, &m)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fmt.Errorf("%s has no role yet", did)
	}
	return &m, nil
}

// IsGovernance tells the backend whether the DID is the network governance.
func (c *ResearchContract) IsGovernance(ctx Ctx, did string) (bool, error) {
	g, err := ctx.GetStub().GetState("GOVERNANCE")
	if err != nil {
		return false, err
	}
	return g != nil && string(g) == did, nil
}
