#!/usr/bin/env bash
# Step 1 - download Fabric docker images, binaries and fabric-samples (needs internet, ~2-5 GB).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d fabric-samples ]; then
  echo "fabric-samples already present - ensuring Docker images are pulled..."
  if [ -f install-fabric.sh ]; then
    ./install-fabric.sh docker
  fi
  echo "Fabric images ready. Next: scripts/start-network.sh"
  exit 0
fi
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh
./install-fabric.sh docker samples binary
echo "Fabric installed. Next: scripts/start-network.sh"
