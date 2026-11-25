package com.researchip.config;

import io.grpc.Grpc;
import io.grpc.ManagedChannel;
import io.grpc.TlsChannelCredentials;
import org.hyperledger.fabric.client.Contract;
import org.hyperledger.fabric.client.Gateway;
import org.hyperledger.fabric.client.identity.Identities;
import org.hyperledger.fabric.client.identity.Identity;
import org.hyperledger.fabric.client.identity.Signer;
import org.hyperledger.fabric.client.identity.Signers;
import org.hyperledger.fabric.client.identity.X509Identity;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.io.Reader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

/** Connects the backend to the Fabric peer as one fixed user (User1 of Org1). */
@Configuration
public class FabricConfig {

    @Value("${fabric.channel}") private String channelName;
    @Value("${fabric.chaincode}") private String chaincodeName;
    @Value("${fabric.msp-id}") private String mspId;
    @Value("${fabric.peer-endpoint}") private String peerEndpoint;
    @Value("${fabric.peer-host-alias}") private String peerHostAlias;
    @Value("${fabric.crypto-path}") private String cryptoPath;
    @Value("${fabric.user}") private String user;

    @Bean(destroyMethod = "shutdownNow")
    public ManagedChannel fabricChannel() throws Exception {
        Path tlsCert = Path.of(cryptoPath, "peers", peerHostAlias, "tls", "ca.crt");
        var creds = TlsChannelCredentials.newBuilder().trustManager(tlsCert.toFile()).build();
        return Grpc.newChannelBuilder(peerEndpoint, creds).overrideAuthority(peerHostAlias).build();
    }

    @Bean(destroyMethod = "close")
    public Gateway fabricGateway(ManagedChannel channel) throws Exception {
        Path userMsp = Path.of(cryptoPath, "users", user, "msp");
        X509Certificate cert;
        try (Reader r = Files.newBufferedReader(firstFile(userMsp.resolve("signcerts")))) {
            cert = Identities.readX509Certificate(r);
        }
        PrivateKey key;
        try (Reader r = Files.newBufferedReader(firstFile(userMsp.resolve("keystore")))) {
            key = Identities.readPrivateKey(r);
        }
        Identity identity = new X509Identity(mspId, cert);
        Signer signer = Signers.newPrivateKeySigner(key);
        return Gateway.newInstance()
                .identity(identity)
                .signer(signer)
                .connection(channel)
                .evaluateOptions(o -> o.withDeadlineAfter(5, TimeUnit.SECONDS))
                .endorseOptions(o -> o.withDeadlineAfter(15, TimeUnit.SECONDS))
                .submitOptions(o -> o.withDeadlineAfter(5, TimeUnit.SECONDS))
                .commitStatusOptions(o -> o.withDeadlineAfter(1, TimeUnit.MINUTES))
                .connect();
    }

    @Bean
    public Contract researchContract(Gateway gateway) {
        return gateway.getNetwork(channelName).getContract(chaincodeName);
    }

    private static Path firstFile(Path dir) throws Exception {
        try (Stream<Path> s = Files.list(dir)) {
            return s.sorted().findFirst()
                    .orElseThrow(() -> new IllegalStateException("No file found in " + dir.toAbsolutePath()));
        }
    }
}
