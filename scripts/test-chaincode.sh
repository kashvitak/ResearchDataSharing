#!/usr/bin/env bash
# Step 4 (optional but recommended) - smoke-test the chaincode with the peer CLI,
# BEFORE starting the backend. Uses dummy public keys; it only tests the chaincode rules.
# Run on a freshly started network:  scripts/start-network.sh && scripts/deploy-chaincode.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"

inv() {
  peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" -C mychannel -n research \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_TLS" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_TLS" \
    -c "$1" 2>&1 | grep -E "Chaincode invoke|Error|error" || true
  sleep 3
}
qry() { peer chaincode query -C mychannel -n research -c "$1"; echo; }

GOV=did:fabric:network:gov; ADMIN=did:fabric:snu:admin
ALICE=did:fabric:snu:alice; BOB=did:fabric:snu:bob; CAROL=did:fabric:iitd:carol
H1=$(printf 'a%.0s' $(seq 64)); H2=$(printf 'b%.0s' $(seq 64))

echo "== 1. register DIDs"
inv "{\"function\":\"CreateDID\",\"Args\":[\"$GOV\",\"key-gov\",\"network\"]}"
inv "{\"function\":\"CreateDID\",\"Args\":[\"$ADMIN\",\"key-admin\",\"snu\"]}"
inv "{\"function\":\"CreateDID\",\"Args\":[\"$ALICE\",\"key-alice\",\"snu\"]}"
inv "{\"function\":\"CreateDID\",\"Args\":[\"$BOB\",\"key-bob\",\"snu\"]}"
inv "{\"function\":\"CreateDID\",\"Args\":[\"$CAROL\",\"key-carol\",\"iitd\"]}"

echo "== 2. governance + organisation + roles"
inv "{\"function\":\"InitNetwork\",\"Args\":[\"$GOV\"]}"
inv "{\"function\":\"AddOrganization\",\"Args\":[\"$GOV\",\"snu\",\"$ADMIN\"]}"
inv "{\"function\":\"AssignRole\",\"Args\":[\"$ADMIN\",\"$ALICE\",\"CSE\",\"RESEARCHER\"]}"
inv "{\"function\":\"AssignRole\",\"Args\":[\"$ADMIN\",\"$BOB\",\"CSE\",\"RESEARCHER\"]}"

echo "== 3. register an asset (Alice)"
inv "{\"function\":\"RegisterAsset\",\"Args\":[\"$ALICE\",\"DS1\",\"climate.csv\",\"QmOldCid\",\"$H1\",\"CONFIDENTIAL\"]}"
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"DS1\"]}"

echo "== 4. Alice proposes an update -> asset locked until Bob approves"
inv "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"DS1\",\"QmNewCid\",\"$H2\",\"1\"]}"
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"DS1\"]}"

echo "== 5. Bob approves -> committed as version 2"
inv "{\"function\":\"ApproveUpdate\",\"Args\":[\"$BOB\",\"DS1\",\"1\"]}"
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"DS1\"]}"

echo "== 6. Carol (other university, no role) must be DENIED"
inv "{\"function\":\"GetAsset\",\"Args\":[\"$CAROL\",\"DS1\"]}"

echo "== 7. provenance history"
qry "{\"function\":\"GetAssetHistory\",\"Args\":[\"$ALICE\",\"DS1\"]}"
