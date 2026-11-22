package com.researchip.service;

import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

/** Talks to the IPFS (Kubo) HTTP API. Only ENCRYPTED bytes ever reach IPFS. */
@Service
public class IpfsService {
    private final RestClient client;

    public IpfsService(@Value("${ipfs.api}") String api) {
        SimpleClientHttpRequestFactory f = new SimpleClientHttpRequestFactory();
        f.setConnectTimeout(5_000);
        f.setReadTimeout(60_000);
        this.client = RestClient.builder().baseUrl(api).requestFactory(f).build();
    }

    /** Stores bytes on IPFS and returns the CID. */
    public String add(byte[] data) {
        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        body.add("file", new ByteArrayResource(data) {
            @Override
            public String getFilename() {
                return "asset.bin";
            }
        });
        try {
            JsonNode r = client.post().uri("/api/v0/add?pin=true")
                    .contentType(MediaType.MULTIPART_FORM_DATA).body(body)
                    .retrieve().body(JsonNode.class);
            return r.get("Hash").asText();
        } catch (Exception e) {
            throw new ApiException(502, "IPFS add failed (is the IPFS container running?): " + e.getMessage());
        }
    }

    public byte[] cat(String cid) {
        if (!cid.matches("^[A-Za-z0-9]{20,100}$")) throw new ApiException(400, "Invalid CID");
        try {
            return client.post().uri("/api/v0/cat?arg={cid}", cid).retrieve().body(byte[].class);
        } catch (Exception e) {
            throw new ApiException(502, "IPFS read failed: " + e.getMessage());
        }
    }
}
