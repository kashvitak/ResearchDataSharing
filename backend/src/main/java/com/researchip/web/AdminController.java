package com.researchip.web;

import com.researchip.service.FabricService;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/admin")
public class AdminController {
    record OrgReq(String org, String adminDid) {}
    record RoleReq(String did, String dept, String role) {}

    private final FabricService fabric;

    public AdminController(FabricService fabric) {
        this.fabric = fabric;
    }

    /** One-time: the calling DID becomes the network governance. Do this right after deployment. */
    @PostMapping("/init")
    public Map<String, Object> init(@RequestAttribute("did") String did) {
        fabric.submit("InitNetwork", did);
        return Map.of("ok", true);
    }

    /** Governance onboards an organisation and names its admin. */
    @PostMapping("/organizations")
    public Map<String, Object> addOrg(@RequestAttribute("did") String did, @RequestBody OrgReq r) {
        fabric.submit("AddOrganization", did, r.org(), r.adminDid());
        return Map.of("ok", true);
    }

    /** Org admin assigns a role + department to a user of their own organisation. */
    @PostMapping("/roles")
    public Map<String, Object> assign(@RequestAttribute("did") String did, @RequestBody RoleReq r) {
        fabric.submit("AssignRole", did, r.did(), r.dept(), r.role());
        return Map.of("ok", true);
    }

    @DeleteMapping("/roles")
    public Map<String, Object> remove(@RequestAttribute("did") String did, @RequestParam("did") String target) {
        fabric.submit("RemoveRole", did, target);
        return Map.of("ok", true);
    }
}
