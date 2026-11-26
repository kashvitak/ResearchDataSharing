#!/usr/bin/env bash
# Concurrency test: two updates to the SAME asset version are submitted at the same time.
# Expected: the ledger accepts exactly ONE; the other is invalidated at commit time
# (MVCC_READ_CONFLICT) or refused by the chaincode's lock/version check.
#
# NOTE: `peer chaincode invoke` only reports that the transaction was handed to the orderer.
# It does NOT wait for the commit, so both CLI calls print "invoke successful" even when the
# ledger later invalidates one of them. The truth is read back from the ledger instead:
# only valid transactions leave a PROPOSE entry in the provenance history.
#
# Usage (from repo root, network running, chaincode deployed):
#   ./scripts/concurrency-test.sh | tee docs/concurrency-test-output.txt
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
sleep 4
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"$ASSET\"]}"

echo "== two updates to version 1 are submitted AT THE SAME TIME"
OUT1=$(mktemp); OUT2=$(mktemp)
invoke "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"$ASSET\",\"QmCidFromTx1\",\"$H2\",\"1\"]}" > "$OUT1" &
invoke "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"$ASSET\",\"QmCidFromTx2\",\"$H3\",\"1\"]}" > "$OUT2" &
wait
echo "-- CLI answer, transaction 1 (only confirms hand-over to the orderer):"
grep -E "invoke successful|Error" "$OUT1" | head -2
echo "-- CLI answer, transaction 2 (only confirms hand-over to the orderer):"
grep -E "invoke successful|Error" "$OUT2" | head -2

echo "== waiting for the block to be committed..."
sleep 6

echo "== what the LEDGER accepted"
echo "-- asset:"
qry "{\"function\":\"GetAsset\",\"Args\":[\"$ALICE\",\"$ASSET\"]}"
echo "-- winning proposal:"
qry "{\"function\":\"GetProposal\",\"Args\":[\"$ALICE\",\"$ASSET\"]}"
echo "-- provenance history:"
HIST=$(qry "{\"function\":\"GetAssetHistory\",\"Args\":[\"$ALICE\",\"$ASSET\"]}")
echo "$HIST"

ACCEPTED=$(echo "$HIST" | grep -o '"action":"PROPOSE"' | wc -l)
echo "== RESULT"
if [ "$ACCEPTED" -eq 1 ]; then
  echo "PASS: 2 updates were submitted concurrently; the ledger accepted exactly 1 and invalidated the other."
else
  echo "FAIL: the ledger accepted $ACCEPTED of the 2 concurrent updates (expected exactly 1)."
fi
rm -f "$OUT1" "$OUT2"
