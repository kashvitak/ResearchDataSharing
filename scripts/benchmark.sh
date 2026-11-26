#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ResearchVault — Live Fabric TPS & Latency Benchmark (v2)
# Uses EXISTING registered DIDs and assets on the live network.
# ──────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TN="$ROOT/fabric-samples/test-network"
export PATH="$ROOT/fabric-samples/bin:/Users/shreegattani/.docker/bin:/opt/homebrew/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/fabric-samples/config/"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$TN/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TN/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051
export ORDERER_CA="$TN/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
ORG1_TLS="$CORE_PEER_TLS_ROOTCERT_FILE"
ORG2_TLS="$TN/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"

RESULTS_FILE="$ROOT/docs/fabric-benchmark-output.txt"
mkdir -p "$(dirname "$RESULTS_FILE")"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

inv() {
  peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" -C mychannel -n research \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_TLS" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_TLS" \
    -c "$1" 2>&1
}
qry() { peer chaincode query -C mychannel -n research -c "$1" 2>&1; }

TOTAL_TX=0; TOTAL_MS=0
declare -a LATENCIES=(); declare -a LABELS=(); declare -a RESULTS=()

record() {
  local label="$1" elapsed="$2" status="$3"
  TOTAL_TX=$(( TOTAL_TX + 1 )); TOTAL_MS=$(( TOTAL_MS + elapsed ))
  LATENCIES+=("$elapsed"); LABELS+=("$label"); RESULTS+=("$status")
  printf "  %-35s  %5d ms   %s\n" "$label" "$elapsed" "$status"
}

timed_inv() {
  local label="$1" args="$2"
  local t0; t0=$(now_ms)
  local out; out=$(inv "$args")
  local t1; t1=$(now_ms)
  local elapsed=$(( t1 - t0 ))
  local st="OK"
  if echo "$out" | grep -qi "error"; then st="ERROR"; fi
  if echo "$out" | grep -qi "successful"; then st="OK"; fi
  record "$label" "$elapsed" "$st"
  sleep 1
}

timed_qry() {
  local label="$1" args="$2"
  local t0; t0=$(now_ms)
  local out; out=$(qry "$args")
  local t1; t1=$(now_ms)
  local elapsed=$(( t1 - t0 ))
  local st="OK"
  if echo "$out" | grep -qi "error\|Error"; then st="ERROR"; fi
  record "$label" "$elapsed" "$st"
}

# ── Existing DIDs in the network ──
ALICE="did:fabric:snu:alice"
KASHVI="did:fabric:snu:kashvi"
BOB="did:fabric:snu:bob"
SHREE="did:fabric:snu:shree"
ADMIN="did:fabric:snu:admin"

{
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   ResearchVault — Live Fabric Benchmark Results                 ║"
echo "║   Network : Hyperledger Fabric 2.5 (Raft, 1 orderer, 2 peers)  ║"
echo "║   Channel : mychannel                                          ║"
echo "║   Chaincode: research v1.0                                     ║"
echo "║   Date    : $(date '+%Y-%m-%d %H:%M:%S %Z')                             ║"
echo "║   Host    : $(uname -m) macOS, Docker Desktop                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Phase 1: Create new DIDs (write benchmark) ──────────────
echo "━━━ Phase 1: DID Creation — 10 new identities ━━━"
for i in $(seq 1 10); do
  timed_inv "CreateDID bench-$i" \
    "{\"function\":\"CreateDID\",\"Args\":[\"did:fabric:bench:perf$i\",\"pubkey-perf-$i\",\"bench\"]}"
done

# ── Phase 2: Read existing assets (query benchmark) ─────────
echo ""
echo "━━━ Phase 2: GetAsset queries — existing asset SA-002 (10×) ━━━"
for i in $(seq 1 10); do
  timed_qry "GetAsset SA-002 (#$i)" \
    "{\"function\":\"GetAsset\",\"Args\":[\"$KASHVI\",\"SA-002\"]}"
done

# ── Phase 3: Asset registration (using existing admin) ──────
echo ""
echo "━━━ Phase 3: RegisterAsset — 10 new assets by alice ━━━"
for i in $(seq 1 10); do
  AHASH=$(python3 -c "import hashlib; print(hashlib.sha256(b'benchmark-asset-$i').hexdigest())")
  timed_inv "RegisterAsset BM-$i" \
    "{\"function\":\"RegisterAsset\",\"Args\":[\"$ALICE\",\"BM-$i\",\"benchmark-$i.csv\",\"QmBenchCid$i\",\"$AHASH\",\"INTERNAL\"]}"
done

# ── Phase 4: GetAssetHistory queries ─────────────────────────
echo ""
echo "━━━ Phase 4: GetAssetHistory — SA-002 (10×) ━━━"
for i in $(seq 1 10); do
  timed_qry "GetAssetHistory SA-002 (#$i)" \
    "{\"function\":\"GetAssetHistory\",\"Args\":[\"$ALICE\",\"SA-002\"]}"
done

# ── Phase 5: ProposeUpdate + ApproveUpdate cycles ────────────
echo ""
echo "━━━ Phase 5: ProposeUpdate + ApproveUpdate — 5 full cycles ━━━"
for i in $(seq 1 5); do
  UHASH=$(python3 -c "import hashlib; print(hashlib.sha256(b'update-$i-benchmark').hexdigest())")
  timed_inv "ProposeUpdate BM-$i" \
    "{\"function\":\"ProposeUpdate\",\"Args\":[\"$ALICE\",\"BM-$i\",\"QmUpdCid$i\",\"$UHASH\",\"1\"]}"
  # Approve with kashvi (PROJECT_LEAD in CSE)
  timed_inv "ApproveUpdate BM-$i" \
    "{\"function\":\"ApproveUpdate\",\"Args\":[\"$KASHVI\",\"BM-$i\",\"1\"]}"
done

# ── Phase 6: GetAuditLog queries ─────────────────────────────
echo ""
echo "━━━ Phase 6: GetAuditLog queries (5×) ━━━"
for did in "$ALICE" "$KASHVI" "$BOB" "$SHREE" "$ADMIN"; do
  short=$(echo "$did" | sed 's/did:fabric:snu://')
  timed_qry "GetAuditLog $short" \
    "{\"function\":\"GetAuditLog\",\"Args\":[\"$KASHVI\",\"$did\"]}"
done

# ── Phase 7: Grant + Access (read-after-grant) ───────────────
echo ""
echo "━━━ Phase 7: GrantAccess + RecordAccess (5 cycles) ━━━"
for i in $(seq 1 5); do
  timed_inv "GrantAccess BM-$i→bob" \
    "{\"function\":\"GrantAccess\",\"Args\":[\"$ALICE\",\"BM-$i\",\"$BOB\"]}"
  timed_inv "RecordAccess BM-$i bob" \
    "{\"function\":\"RecordAccess\",\"Args\":[\"$BOB\",\"BM-$i\"]}"
done

# ═══════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                       BENCHMARK SUMMARY                         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Count successes
OK_COUNT=0; ERR_COUNT=0
for r in "${RESULTS[@]}"; do
  if [ "$r" = "OK" ]; then OK_COUNT=$((OK_COUNT+1)); else ERR_COUNT=$((ERR_COUNT+1)); fi
done
echo "Total operations    : $TOTAL_TX  ($OK_COUNT succeeded, $ERR_COUNT errors)"
echo "Total elapsed       : ${TOTAL_MS} ms"
if [ "$TOTAL_TX" -gt 0 ]; then
  AVG=$(( TOTAL_MS / TOTAL_TX ))
  echo "Avg latency/op      : ${AVG} ms"
fi

echo ""
echo "── Per-Operation-Type Breakdown ──"

calc_avg() {
  local pattern="$1" label="$2" sum=0 count=0 ok=0
  for idx in "${!LABELS[@]}"; do
    if [[ "${LABELS[$idx]}" == $pattern* ]]; then
      sum=$(( sum + ${LATENCIES[$idx]} ))
      count=$(( count + 1 ))
      if [ "${RESULTS[$idx]}" = "OK" ]; then ok=$((ok+1)); fi
    fi
  done
  if [ "$count" -gt 0 ]; then
    local a=$(( sum / count ))
    printf "  %-32s  %3d ops  avg %5d ms  (%d OK)\n" "$label" "$count" "$a" "$ok"
  fi
}

calc_avg "CreateDID"       "CreateDID (invoke)"
calc_avg "RegisterAsset"   "RegisterAsset (invoke)"
calc_avg "GetAsset"        "GetAsset (query)"
calc_avg "GetAssetHistory"  "GetAssetHistory (query)"
calc_avg "ProposeUpdate"   "ProposeUpdate (invoke)"
calc_avg "ApproveUpdate"   "ApproveUpdate (invoke)"
calc_avg "GetAuditLog"     "GetAuditLog (query)"
calc_avg "GrantAccess"     "GrantAccess (invoke)"
calc_avg "RecordAccess"    "RecordAccess (invoke)"

# TPS for successful invokes only
echo ""
INV_OK_COUNT=0; INV_OK_MS=0
QRY_OK_COUNT=0; QRY_OK_MS=0
for idx in "${!LABELS[@]}"; do
  if [ "${RESULTS[$idx]}" = "OK" ]; then
    case "${LABELS[$idx]}" in
      GetAsset*|GetAssetHistory*|GetAuditLog*)
        QRY_OK_COUNT=$((QRY_OK_COUNT+1))
        QRY_OK_MS=$((QRY_OK_MS + ${LATENCIES[$idx]}))
        ;;
      *)
        INV_OK_COUNT=$((INV_OK_COUNT+1))
        INV_OK_MS=$((INV_OK_MS + ${LATENCIES[$idx]}))
        ;;
    esac
  fi
done

echo "── Throughput (successful operations only) ──"
if [ "$INV_OK_MS" -gt 0 ]; then
  TPS_INV=$(python3 -c "print(f'{${INV_OK_COUNT} / (${INV_OK_MS}/1000):.2f}')")
  echo "  Invoke TPS (sustained)  : $TPS_INV tx/s  ($INV_OK_COUNT invokes, ${INV_OK_MS} ms pure time)"
fi
if [ "$QRY_OK_MS" -gt 0 ]; then
  TPS_QRY=$(python3 -c "print(f'{${QRY_OK_COUNT} / (${QRY_OK_MS}/1000):.2f}')")
  echo "  Query  TPS (sustained)  : $TPS_QRY q/s   ($QRY_OK_COUNT queries, ${QRY_OK_MS} ms pure time)"
fi
ALL_OK=$((INV_OK_COUNT + QRY_OK_COUNT))
ALL_MS=$((INV_OK_MS + QRY_OK_MS))
if [ "$ALL_MS" -gt 0 ]; then
  TPS_ALL=$(python3 -c "print(f'{${ALL_OK} / (${ALL_MS}/1000):.2f}')")
  echo "  Combined TPS            : $TPS_ALL ops/s ($ALL_OK ops, ${ALL_MS} ms)"
fi

echo ""
echo "── All Individual Latencies ──"
for idx in "${!LABELS[@]}"; do
  printf "  [%2d]  %-35s  %5d ms  %s\n" "$((idx+1))" "${LABELS[$idx]}" "${LATENCIES[$idx]}" "${RESULTS[$idx]}"
done

echo ""
echo "── Environment ──"
echo "  Fabric Version  : 2.5.x"
echo "  Consensus       : Raft (single orderer)"
echo "  Peers           : 2 (Org1 + Org2)"
echo "  State DB        : CouchDB"
echo "  Endorsement     : MAJORITY (Org1MSP + Org2MSP)"
echo "  TLS             : Enabled"
echo "  Host            : macOS $(sw_vers -productVersion 2>/dev/null || echo 'N/A'), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon'), Docker Desktop"
echo ""
echo "Benchmark complete at $(date '+%Y-%m-%d %H:%M:%S %Z')."

} 2>&1 | tee "$RESULTS_FILE"

echo ""
echo "Results saved to: $RESULTS_FILE"
