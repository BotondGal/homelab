#!/usr/bin/env bash
set -euo pipefail

TARGET=${1:-""}   # z.B. "namespaces/ai-services"

if [ -z "$TARGET" ]; then
  echo "Usage: ./deploy.sh <kustomization-path>"
  echo "  e.g: ./deploy.sh namespaces/ai-services"
  exit 1
fi

echo "▶ Deploying $TARGET..."

find secrets/ -name "*.enc.yaml" | while read -r secret_file; do
  echo "  🔑 Applying secret: $secret_file"
  sops --decrypt "$secret_file" | kubectl apply -f -
done

# Dann die Kustomization anwenden
kubectl apply -k "$TARGET"

echo "✅ Done."