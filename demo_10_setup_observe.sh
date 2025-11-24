#!/usr/bin/env bash
set -euo pipefail
source ./demo_00_env.sh
ns="${NAMESPACE}"

echo "[Observe] Showing created resources in namespace: $ns"
kubectl get sa,role,rolebinding,pdb -n "$ns" -o wide || true

echo
echo "[Observe] RBAC checks by impersonating the ServiceAccount:"
kubectl auth can-i --as="system:serviceaccount:${ns}:scale-burst" --namespace "$ns" '*' 'deployments.apps' || true
kubectl auth can-i --as="system:serviceaccount:${ns}:scale-burst" --namespace "$ns" '*' 'services' || true
kubectl auth can-i --as="system:serviceaccount:${ns}:scale-burst" --namespace "$ns" 'get,list,watch,delete' 'pods' || true

echo
echo "[Observe] PodDisruptionBudget details:"
kubectl describe pdb burst-pdb -n "$ns" || true
echo
echo "[Observe] PDB minAvailable:"
kubectl get pdb burst-pdb -n "$ns" -o jsonpath='{.spec.minAvailable}'; echo

echo
echo "[Observe] NodePool label status (ignore if resource not present):"
kubectl get nodepool -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels --no-headers || echo "No 'nodepool' resource found (this is OK)."
