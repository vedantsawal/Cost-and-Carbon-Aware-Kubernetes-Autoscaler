#!/usr/bin/env bash
# Confirms cleanup
set -euo pipefail
source ./00_env.sh

echo "# Deployments (should be none):"
kubectl -n "$NAMESPACE" get deploy -l group=scale-burst || true
echo

echo "# Pods (should be none):"
kubectl -n "$NAMESPACE" get pods -l group=scale-burst || true
echo

echo "# PDB (should be NotFound or empty list):"
kubectl -n "$NAMESPACE" get pdb burst-pdb || true
