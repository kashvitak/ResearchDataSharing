#!/usr/bin/env bash
# Step 3 - package, install, approve (both orgs) and commit the chaincode.
# First deploy:  scripts/deploy-chaincode.sh
# After editing chaincode:  scripts/deploy-chaincode.sh 1.1 2   (new version, next sequence number)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0}"
SEQUENCE="${2:-1}"

( cd "$ROOT/chaincode/research-ip" && go mod tidy )

cd "$ROOT/fabric-samples/test-network"
./network.sh deployCC -c mychannel -ccn research -ccp "$ROOT/chaincode/research-ip" -ccl go -ccv "$VERSION" -ccs "$SEQUENCE"
