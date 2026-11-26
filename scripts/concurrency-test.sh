#!/usr/bin/env bash
# Concurrency test: two updates to the SAME asset version are submitted at the same time.
# Expected result: exactly ONE is accepted, the other is rejected (MVCC conflict or the
# chaincode's "open proposal / locked" check). This demonstrates conflict control on the ledger.
#
# Usage (from repo root, with the network running and the chaincode deployed):
#   ./scripts/concurrency-test.sh | tee docs/concurrency-test-output.txt
#
# It is safe to run on a ledger that already has the demo DIDs: setup errors such as
# "already exists" are ignored, and the test uses its own asset id.
set -uo pipefail
source "$(dirname "$0")/env.sh"

invoke() {
  peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" -C mychannel -n research \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_TLS" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_TLS" \
    -c "$1" 2>&1
}
quiet() { invoke "$1" >/dev/null 2>&1 || true; sleep 3; }
qry() { peer chaincode query -C mychannel -n research -c "$1" 2>&1; echo; }

GOV=did:fabric:network:gov; ADMIN=did:fabric:snu:admin
ALICE=did:fabric:snu:alice; BOB=did:fabric:snu:bob
ASSET="DS-CONC-$(date +%s)"
H1=$(printf 'a%.0s' $(seq 64)); H2=$(printf 'b%.0s' $(seq 64)); H3=$(printf 'c%.0s' $(seq 64))

echo "== setup (errors like 'already exists' are ignored)"
quiet "{\"function\":\"CreateDID\",\"Args\":[\"$GOV\",\"key-gov\",\"network\"]}"
quiet "{\"function\":\"CreateDID\",\"Args\":[\"$ADMIN\",\"key-admin\",\"snu\"]}"
quiet "{\"function\":\"CreateDID\",\"Args\":[\"$ALICE\",\"key-alice\",\"snu\"]}"
quiet "{\"function\":\"CreateDID\",\"Args\":[\"$BOB\",\"key-bob\",\"snu\"]}"
quiet "{\"function\":\"InitNetwork\",\"Args\":[\"$GOV\"]}"
quiet "{\"function\":\"AddOrganization\",\"Args\":[\"$GOV\",\"snu\",\"$ADMIN\"]}"
quiet "{\"function\":\"AssignRole\",\"Args\":[\"$ADMIN\",\"$ALICE\",\"CSE\",\"RESEARCHER\"]}"
quiet "{\"function\":\"AssignRole\",\"Args\":[\"$ADMIN\",\"$BOB\",\"CSE\",\"RESEARCHER\"]}"

echo "== register asset $ASSET (version 1)"
invoke "{\"function\":\"RegisterAsset\",\"Args\":[\"$ALICE\",\"$ASSET\",\"conc.csv\",\"QmBaseCid\",\"$H1\",\"CONFIDENTIAL\"]}" | grep -E "invoke successful|Error" || true
sleep 3
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"$ASSET\"]}"

echo "== two users propose an update to version 1 AT THE SAME TIME"
OUT1=$(mktemp); OUT2=$(mktemp)
invoke "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"$ASSET\",\"QmCidFromTx1\",\"$H2\",\"1\"]}" > "$OUT1" &
invoke "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"$ASSET\",\"QmCidFromTx2\",\"$H3\",\"1\"]}" > "$OUT2" &
wait
sleep 3

echo
echo "-- transaction 1:"; grep -E "invoke successful|Error|MVCC|invalid|locked|proposal" "$OUT1" | head -3
echo "-- transaction 2:"; grep -E "invoke successful|Error|MVCC|invalid|locked|proposal" "$OUT2" | head -3

OK=$(grep -l "invoke successful" "$OUT1" "$OUT2" 2>/dev/null | wc -l)
echo
echo "== final state of $ASSET"
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"$ASSET\"]}"

echo "== RESULT"
if [ "$OK" -eq 1 ]; then
  echo "PASS: exactly 1 of 2 concurrent updates was accepted; the other was rejected."
else
  echo "FAIL: $OK of 2 concurrent updates were accepted (expected exactly 1)."
fi
rm -f "$OUT1" "$OUT2"