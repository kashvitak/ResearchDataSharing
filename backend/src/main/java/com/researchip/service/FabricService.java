package com.researchip.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.hyperledger.fabric.client.Contract;
import org.hyperledger.fabric.client.GatewayException;
import org.springframework.stereotype.Service;

/** Thin wrapper around the chaincode: submit = write transaction, evaluate = read-only query. */
@Service
public class FabricService {
    private final Contract contract;
    private final ObjectMapper mapper = new ObjectMapper();

    public FabricService(Contract contract) {
        this.contract = contract;
    }

    public JsonNode submit(String fn, String... args) {
        try {
            return parse(contract.submitTransaction(fn, args));
        } catch (Exception e) {
            throw new ApiException(400, message(e));
        }
    }

    public JsonNode evaluate(String fn, String... args) {
        try {
            return parse(contract.evaluateTransaction(fn, args));
        } catch (Exception e) {
            throw new ApiException(400, message(e));
        }
    }

    private JsonNode parse(byte[] bytes) throws Exception {
        if (bytes == null || bytes.length == 0) return mapper.nullNode();
        return mapper.readTree(bytes);
    }

    /** Pulls the chaincode's own error text ("access denied: ...") out of the gateway exception. */
    private static String message(Exception e) {
        String msg = e.getMessage();
        if (e instanceof GatewayException ge) {
            var details = ge.getDetails();
            if (details != null && !details.isEmpty() && details.get(0).getMessage() != null) {
                msg = details.get(0).getMessage();
            }
        }
        if (msg == null) msg = e.getClass().getSimpleName();
        return msg.replaceFirst("^.*chaincode response \\d+, ", "");
    }
}
