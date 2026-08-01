#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

TS_IP=""
for i in $(seq 1 30); do
    if TS_IP=$(tailscale ip -4 2>/dev/null); then
        break
    fi
    echo "Waiting for tailscale to connect..."
    sleep 2
done

if [ -z "$TS_IP" ]; then
    echo "tailscale did not come up in time" >&2
    exit 1
fi

echo "TS_IP=${TS_IP}" > .env

exec docker compose up -d
