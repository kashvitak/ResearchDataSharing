package com.researchip.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.researchip.service.AuthService;
import com.researchip.service.FabricService;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.*;

import java.util.HashMap;
import java.util.Map;

@RestController
@RequestMapping("/api")
public class AuthController {
    record RegisterReq(String did, String publicKey, String org) {}
    record ChallengeReq(String did) {}
    record LoginReq(String did, String challenge, String signature) {}

    private final AuthService auth;
    private final FabricService fabric;

    public AuthController(AuthService auth, FabricService fabric) {
        this.auth = auth;
        this.fabric = fabric;
    }

    /** Creates the DID on Fabric. Only the PUBLIC key is sent. */
    @PostMapping("/auth/register")
    public Map<String, Object> register(@RequestBody RegisterReq r) {
        fabric.submit("CreateDID", r.did(), r.publicKey(), r.org());
        return Map.of("ok", true);
    }

    @PostMapping("/auth/challenge")
    public Map<String, String> challenge(@RequestBody ChallengeReq r) {
        return Map.of("challenge", auth.newChallenge(r.did()));
    }

    @PostMapping("/auth/login")
    public Map<String, String> login(@RequestBody LoginReq r) {
        return Map.of("token", auth.login(r.did(), r.challenge(), r.signature()), "did", r.did());
    }

    @PostMapping("/logout")
    public Map<String, Object> logout(HttpServletRequest req) {
        auth.logout(req.getHeader("Authorization").substring(7));
        return Map.of("ok", true);
    }

    /** Who am I? org / department / role (member is null until an admin assigns a role). */
    @GetMapping("/me")
    public Map<String, Object> me(@RequestAttribute("did") String did) {
        Map<String, Object> out = new HashMap<>();
        out.put("did", did);
        JsonNode member = null;
        try {
            member = fabric.evaluate("GetMember", did);
        } catch (Exception ignored) {
            // no role yet
        }
        out.put("member", member);
        out.put("governance", fabric.evaluate("IsGovernance", did).asBoolean());
        return out;
    }
}
