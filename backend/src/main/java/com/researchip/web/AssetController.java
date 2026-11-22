package com.researchip.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.researchip.service.ApiException;
import com.researchip.service.CryptoService;
import com.researchip.service.FabricService;
import com.researchip.service.IpfsService;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Upload flow:   file -> SHA-256 -> AES-256-GCM encrypt -> IPFS (CID) -> Fabric (owner, hash, CID)
 * Download flow: Fabric (logged access check) -> IPFS -> decrypt -> compare SHA-256 with Fabric -> file
 */
@RestController
@RequestMapping("/api/assets")
public class AssetController {
    record VoteReq(int nonce, String reason) {}
    record GrantReq(String did) {}
    record TransferReq(String newOwnerDid, int expectedVersion) {}

    private final FabricService fabric;
    private final IpfsService ipfs;
    private final CryptoService crypto;

    public AssetController(FabricService fabric, IpfsService ipfs, CryptoService crypto) {
        this.fabric = fabric;
        this.ipfs = ipfs;
        this.crypto = crypto;
    }

    // ------------------------------------------------------------------ queries

    @GetMapping
    public JsonNode list(@RequestAttribute("did") String did) {
        return fabric.evaluate("ListAssets", did);
    }

    @GetMapping("/{id}")
    public JsonNode get(@RequestAttribute("did") String did, @PathVariable String id) {
        return fabric.evaluate("GetAsset", did, id);
    }

    @GetMapping("/{id}/history")
    public JsonNode history(@RequestAttribute("did") String did, @PathVariable String id) {
        return fabric.evaluate("GetAssetHistory", did, id);
    }

    @GetMapping("/{id}/proposal")
    public JsonNode proposal(@RequestAttribute("did") String did, @PathVariable String id) {
        return fabric.evaluate("GetProposal", did, id);
    }

    // ----------------------------------------------------------- register / read

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> register(@RequestAttribute("did") String did,
                                        @RequestParam String assetId,
                                        @RequestParam(required = false) String name,
                                        @RequestParam(defaultValue = "INTERNAL") String classification,
                                        @RequestParam("file") MultipartFile file) throws IOException {
        byte[] plain = file.getBytes();
        String hash = CryptoService.sha256Hex(plain);                 // integrity fingerprint
        String cid = ipfs.add(crypto.encrypt(assetId, plain));        // only ciphertext leaves the backend
        String label = (name == null || name.isBlank()) ? file.getOriginalFilename() : name;
        fabric.submit("RegisterAsset", did, assetId, label, cid, hash, classification);
        return Map.of("assetId", assetId, "cid", cid, "hash", hash);
    }

    @GetMapping("/{id}/download")
    public ResponseEntity<byte[]> download(@RequestAttribute("did") String did, @PathVariable String id) {
        JsonNode result = fabric.submit("AccessAsset", did, id);      // permission check + audit log entry
        JsonNode asset = result.get("asset");
        return fileResponse(id, asset.get("name").asText(), asset.get("cid").asText(), asset.get("hash").asText());
    }

    /** Department approvers review the proposed file before approving. */
    @GetMapping("/{id}/proposal/download")
    public ResponseEntity<byte[]> downloadProposal(@RequestAttribute("did") String did, @PathVariable String id) {
        JsonNode p = fabric.evaluate("GetProposal", did, id);
        JsonNode asset = fabric.evaluate("GetAsset", did, id);
        return fileResponse(id, "proposed-" + asset.get("name").asText(), p.get("newCid").asText(), p.get("newHash").asText());
    }

    private ResponseEntity<byte[]> fileResponse(String assetId, String filename, String cid, String registeredHash) {
        byte[] plain = crypto.decrypt(assetId, ipfs.cat(cid));        // GCM tag failure -> 409
        boolean valid = CryptoService.sha256Hex(plain).equals(registeredHash);
        return ResponseEntity.ok()
                .header("X-Integrity", valid ? "VALID" : "COMPROMISED")
                .header(HttpHeaders.CONTENT_DISPOSITION,
                        ContentDisposition.attachment().filename(filename, StandardCharsets.UTF_8).build().toString())
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .body(plain);
    }

    /** "Is the file I hold the one that was registered?"  Hash it locally, compare with Fabric. */
    @PostMapping(value = "/{id}/verify", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public JsonNode verify(@RequestAttribute("did") String did, @PathVariable String id,
                           @RequestParam("file") MultipartFile file) throws IOException {
        return fabric.evaluate("VerifyAsset", did, id, CryptoService.sha256Hex(file.getBytes()));
    }

    // ------------------------------------------------- peer-verified update flow

    @PostMapping(value = "/{id}/propose", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> propose(@RequestAttribute("did") String did, @PathVariable String id,
                                       @RequestParam int expectedVersion,
                                       @RequestParam("file") MultipartFile file) throws IOException {
        byte[] plain = file.getBytes();
        String hash = CryptoService.sha256Hex(plain);
        String cid = ipfs.add(crypto.encrypt(id, plain));
        fabric.submit("ProposeUpdate", did, id, cid, hash, String.valueOf(expectedVersion));
        return Map.of("cid", cid, "hash", hash);
    }

    @PostMapping("/{id}/approve")
    public Map<String, Object> approve(@RequestAttribute("did") String did, @PathVariable String id, @RequestBody VoteReq r) {
        fabric.submit("ApproveUpdate", did, id, String.valueOf(r.nonce()));
        return Map.of("ok", true);
    }

    @PostMapping("/{id}/reject")
    public Map<String, Object> reject(@RequestAttribute("did") String did, @PathVariable String id, @RequestBody VoteReq r) {
        fabric.submit("RejectUpdate", did, id, String.valueOf(r.nonce()), r.reason() == null ? "" : r.reason());
        return Map.of("ok", true);
    }

    @PostMapping("/{id}/expire")
    public Map<String, Object> expire(@RequestAttribute("did") String did, @PathVariable String id) {
        fabric.submit("ExpireProposal", did, id);
        return Map.of("ok", true);
    }

    // --------------------------------------------------------- share / transfer

    @PostMapping("/{id}/grant")
    public Map<String, Object> grant(@RequestAttribute("did") String did, @PathVariable String id, @RequestBody GrantReq r) {
        if (r.did() == null || r.did().isBlank()) throw new ApiException(400, "did is required");
        fabric.submit("GrantAccess", did, id, r.did());
        return Map.of("ok", true);
    }

    @PostMapping("/{id}/transfer")
    public Map<String, Object> transfer(@RequestAttribute("did") String did, @PathVariable String id, @RequestBody TransferReq r) {
        fabric.submit("TransferAsset", did, id, r.newOwnerDid(), String.valueOf(r.expectedVersion()));
        return Map.of("ok", true);
    }
}
