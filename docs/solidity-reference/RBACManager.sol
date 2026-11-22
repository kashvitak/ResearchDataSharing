// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * RBACManager  -  "What are you allowed to do?"
 * -----------------------------------------------------------------------------
 * Solidity version of our *RBAC chaincode* on Hyperledger Fabric.
 *
 * Every member belongs to exactly one (organisation, department) and holds one
 * role. Permissions are a bitmask per role, so the check is one AND operation.
 * Authorisation is enforced HERE (on-chain), not by hiding buttons in React.
 *
 * deptApprovers[org,dept] = how many members of that department can APPROVE.
 * ResearchAsset reads this to know how many peer approvals an update needs.
 *
 * Concurrency: each membership record has a `version`. Two admins editing the
 * same member at the same time -> the second one reverts with StaleVersion.
 */

interface IDIDRegistry {
    function isActive(address who) external view returns (bool);
}

contract RBACManager {
    enum Role { NONE, COLLABORATOR, RESEARCHER, PROJECT_LEAD, ORG_ADMIN, AUDITOR }

    // permission bits
    uint16 public constant UPLOAD   = 1;
    uint16 public constant READ     = 2;
    uint16 public constant TRANSFER = 4;
    uint16 public constant VERIFY   = 8;
    uint16 public constant AUDIT    = 16;
    uint16 public constant APPROVE  = 32;  // can vote on department updates
    uint16 public constant MANAGE   = 64;  // can assign / revoke roles
    uint16 public constant TRANSFER_IN_ORG = 128; // "limited" transfer: only inside own organisation

    struct Member {
        bytes32 org;      // keccak256("SNU")
        bytes32 dept;     // keccak256("CSE")
        Role    role;
        uint64  version;
        bool    active;
    }

    address public governance;              // consortium governance account (multi-sig in production)
    IDIDRegistry public immutable didRegistry;

    mapping(bytes32 => address) public orgAdmin;      // org => its admin
    mapping(address => Member) private members;
    mapping(bytes32 => uint32) public deptApprovers;  // keccak(org,dept) => #members with APPROVE
    mapping(Role => uint16) public rolePerms;

    error NotGovernance();
    error NotOrgAdmin();
    error NoActiveDID();
    error OrgExists();
    error UserBelongsToOtherOrg();
    error NotAMember();
    error StaleVersion(uint64 expected, uint64 actual);

    event OrganizationAdded(bytes32 indexed org, address admin);
    event RoleAssigned(address indexed user, bytes32 indexed org, bytes32 dept, Role role, uint64 version);
    event RoleRevoked(address indexed user, bytes32 indexed org, uint64 version);

    constructor(address didRegistry_) {
        governance = msg.sender;
        didRegistry = IDIDRegistry(didRegistry_);

        rolePerms[Role.ORG_ADMIN]    = UPLOAD | READ | TRANSFER | VERIFY | AUDIT | MANAGE;
        rolePerms[Role.PROJECT_LEAD] = UPLOAD | READ | TRANSFER | VERIFY | AUDIT | APPROVE;
        rolePerms[Role.RESEARCHER]   = UPLOAD | READ | VERIFY | APPROVE | TRANSFER_IN_ORG;
        rolePerms[Role.COLLABORATOR] = READ | VERIFY;
        rolePerms[Role.AUDITOR]      = READ | VERIFY | AUDIT;
    }

    // ------------------------------------------------------------------ writes

    /// @notice Governance onboards a new university / lab / industry partner.
    function addOrganization(bytes32 org, address admin) external {
        if (msg.sender != governance) revert NotGovernance();
        if (orgAdmin[org] != address(0)) revert OrgExists();
        if (!didRegistry.isActive(admin)) revert NoActiveDID();

        orgAdmin[org] = admin;
        members[admin] = Member(org, keccak256("ADMIN"), Role.ORG_ADMIN, 1, true);
        emit OrganizationAdded(org, admin);
    }

    /// @notice Org admin gives a role (and department) to someone in THEIR org.
    /// @param expectedVersion current membership version (0 for a new member).
    function assignRole(address user, bytes32 dept, Role role, uint64 expectedVersion) external {
        bytes32 org = _callerAdminOrg();
        if (!didRegistry.isActive(user)) revert NoActiveDID();

        Member storage m = members[user];
        if (m.version != 0 && m.org != org) revert UserBelongsToOtherOrg();
        if (m.version != expectedVersion) revert StaleVersion(expectedVersion, m.version);

        _removeFromQuorum(m);                       // old dept loses a voter (if any)
        m.org = org;
        m.dept = dept;
        m.role = role;
        m.active = true;
        m.version += 1;
        _addToQuorum(m);                            // new dept gains a voter (if any)

        emit RoleAssigned(user, org, dept, role, m.version);
    }

    function revokeRole(address user, uint64 expectedVersion) external {
        bytes32 org = _callerAdminOrg();
        Member storage m = members[user];
        if (!m.active) revert NotAMember();
        if (m.org != org) revert UserBelongsToOtherOrg();
        if (m.version != expectedVersion) revert StaleVersion(expectedVersion, m.version);

        _removeFromQuorum(m);
        m.active = false;
        m.role = Role.NONE;
        m.version += 1;
        emit RoleRevoked(user, org, m.version);
    }

    // ------------------------------------------------------------------- reads

    /// @notice The single permission check every other contract calls.
    function hasPermission(address user, uint16 perm) public view returns (bool) {
        Member storage m = members[user];
        return m.active && didRegistry.isActive(user) && (rolePerms[m.role] & perm) == perm;
    }

    function memberOf(address user)
        external
        view
        returns (bytes32 org, bytes32 dept, Role role, uint64 version, bool active)
    {
        Member storage m = members[user];
        return (m.org, m.dept, m.role, m.version, m.active);
    }

    function sameDepartment(address a, address b) external view returns (bool) {
        Member storage x = members[a];
        Member storage y = members[b];
        return x.active && y.active && x.org == y.org && x.dept == y.dept;
    }

    function deptKey(bytes32 org, bytes32 dept) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(org, dept));
    }

    // ---------------------------------------------------------------- internal

    function _callerAdminOrg() private view returns (bytes32 org) {
        Member storage a = members[msg.sender];
        if (!a.active || (rolePerms[a.role] & MANAGE) == 0) revert NotOrgAdmin();
        return a.org;
    }

    function _addToQuorum(Member storage m) private {
        if (m.active && (rolePerms[m.role] & APPROVE) != 0) deptApprovers[deptKey(m.org, m.dept)] += 1;
    }

    function _removeFromQuorum(Member storage m) private {
        if (m.active && (rolePerms[m.role] & APPROVE) != 0) deptApprovers[deptKey(m.org, m.dept)] -= 1;
    }
}
