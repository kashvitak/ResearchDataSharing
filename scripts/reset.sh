#!/usr/bin/env bash
# Rebuild the Fabric network + chaincode from scratch (this WIPES the ledger),
# and make sure IPFS is running.
#
# Usage (from repo root):  ./scripts/reset.sh
#
# Afterwards you must also:
#   1. restart the backend  (Ctrl+C, then: cd backend && source .env.sh && mvn spring-boot:run)
#      -> the backend holds the old TLS certificates until it is restarted
#   2. clear the browser's Local Storage for http://localhost:5173
#   3. register the DIDs again (once each)
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/start-network.sh
./scripts/deploy-chaincode.sh
docker compose up -d

echo
echo "Ledger reset and chaincode redeployed. Next:"
echo "  1. Restart the backend:  cd backend && source .env.sh && mvn spring-boot:run"
echo "  2. Clear Local Storage for http://localhost:5173 (F12 -> Application -> Local Storage)"
echo "  3. Register the DIDs again, once each"