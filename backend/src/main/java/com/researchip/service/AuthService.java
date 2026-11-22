package com.researchip.service;

import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * DID login by challenge-response:
 *   1. backend gives a random challenge
 *   2. the browser signs it with the PRIVATE key (which never leaves the browser)
 *   3. backend checks the signature against the PUBLIC key stored in the DID document on Fabric
 * Sessions and challenges are kept in memory (fine for a prototype).
 */
@Service
public class AuthService {
    private record Challenge(String did, Instant expires) {}
    private record Session(String did, Instant expires) {}

    private final Map<String, Challenge> challenges = new ConcurrentHashMap<>();
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();
    private final FabricService fabric;

    public AuthService(FabricService fabric) {
        this.fabric = fabric;
    }

    public String newChallenge(String did) {
        fabric.evaluate("GetDID", did); // fails if the DID does not exist
        String c = randomHex(32);
        challenges.put(c, new Challenge(did, Instant.now().plusSeconds(120)));
        return c;
    }

    /** Returns a session token if the signature is valid. */
    public String login(String did, String challenge, String signatureB64) {
        Challenge ch = challenges.remove(challenge); // one-time use
        if (ch == null || !ch.did().equals(did) || ch.expires().isBefore(Instant.now())) {
            throw new ApiException(401, "Challenge expired or invalid - try again");
        }
        JsonNode doc = fabric.evaluate("GetDID", did);
        if (!doc.get("active").asBoolean()) throw new ApiException(401, "DID is revoked");
        boolean ok;
        try {
            PublicKey pub = KeyFactory.getInstance("EC")
                    .generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(doc.get("publicKey").asText())));
            Signature sig = Signature.getInstance("SHA256withECDSAinP1363Format"); // WebCrypto's r||s format
            sig.initVerify(pub);
            sig.update(challenge.getBytes(StandardCharsets.UTF_8));
            ok = sig.verify(Base64.getDecoder().decode(signatureB64));
        } catch (Exception e) {
            ok = false;
        }
        if (!ok) throw new ApiException(401, "Signature does not match the DID's public key");
        String token = randomHex(32);
        sessions.put(token, new Session(did, Instant.now().plusSeconds(8 * 3600)));
        return token;
    }

    /** Returns the DID for a valid token, or null. */
    public String didForToken(String token) {
        Session s = sessions.get(token);
        if (s == null) return null;
        if (s.expires().isBefore(Instant.now())) {
            sessions.remove(token);
            return null;
        }
        return s.did();
    }

    public void logout(String token) {
        sessions.remove(token);
    }

    private String randomHex(int bytes) {
        byte[] b = new byte[bytes];
        random.nextBytes(b);
        return HexFormat.of().formatHex(b);
    }
}
