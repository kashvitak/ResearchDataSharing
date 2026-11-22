#!/usr/bin/env bash
# Step 2 - start the 2-org Fabric test network (Org1 + Org2 + orderer, CouchDB state DB)
# and create the channel "mychannel".
set -euo pipefail
cd "$(dirname "$0")/../fabric-samples/test-network"
./network.sh down
./network.sh up createChannel -c mychannel -s couchdb
