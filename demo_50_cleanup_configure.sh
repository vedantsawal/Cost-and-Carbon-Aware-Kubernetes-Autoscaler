#!/usr/bin/env bash
# Deletes burst workloads + PDB + job (keeps NodePools for reuse)
set -euo pipefail
source ./00_env.sh

kubectl -n "$NAMESPACE" delete deploy -l group=scale-burst --ignore-not-found
kubectl -n "$NAMESPACE" delete job burst-deployments --ignore-not-found
kubectl -n "$NAMESPACE" delete pdb burst-pdb --ignore-not-found

echo "[ok] Demo app resources removed from namespace ${NAMESPACE}"
