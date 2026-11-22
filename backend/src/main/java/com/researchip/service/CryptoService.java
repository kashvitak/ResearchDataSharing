package com.researchip.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;

/**
 * AES-256-GCM file encryption + SHA-256 hashing.
 * Each asset gets its own key = HMAC-SHA256(masterKey, assetId), so we need no key database.
 * Stored format: [12-byte random IV][ciphertext + 16-byte GCM tag].
 */
@Service
public class CryptoService {
    private final byte[] master;
    private final SecureRandom random = new SecureRandom();

    public CryptoService(@Value("${app.master-key}") String masterKeyB64) {
        this.master = Base64.getDecoder().decode(masterKeyB64.trim());
        if (master.length < 32) throw new IllegalStateException("MASTER_KEY must be 32 bytes (openssl rand -base64 32)");
    }

    public byte[] encrypt(String assetId, byte[] plain) {
        try {
            byte[] iv = new byte[12];
            random.nextBytes(iv);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, keyFor(assetId), new GCMParameterSpec(128, iv));
            c.updateAAD(assetId.getBytes(StandardCharsets.UTF_8)); // binds the ciphertext to this asset
            byte[] ct = c.doFinal(plain);
            byte[] out = new byte[iv.length + ct.length];
            System.arraycopy(iv, 0, out, 0, iv.length);
            System.arraycopy(ct, 0, out, iv.length, ct.length);
            return out;
        } catch (Exception e) {
            throw new ApiException(500, "Encryption failed: " + e.getMessage());
        }
    }

    /** Throws ApiException(409) if the encrypted file was modified (GCM authentication fails). */
    public byte[] decrypt(String assetId, byte[] data) {
        try {
            if (data.length < 12 + 16) throw new IllegalArgumentException("too short");
            byte[] iv = Arrays.copyOfRange(data, 0, 12);
            byte[] ct = Arrays.copyOfRange(data, 12, data.length);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, keyFor(assetId), new GCMParameterSpec(128, iv));
            c.updateAAD(assetId.getBytes(StandardCharsets.UTF_8));
            return c.doFinal(ct);
        } catch (Exception e) {
            throw new ApiException(409, "INTEGRITY FAILURE: the stored encrypted file failed authentication (modified or wrong key).");
        }
    }

    public static String sha256Hex(byte[] data) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private SecretKeySpec keyFor(String assetId) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(master, "HmacSHA256"));
        return new SecretKeySpec(mac.doFinal(("asset:" + assetId).getBytes(StandardCharsets.UTF_8)), "AES");
    }
}
