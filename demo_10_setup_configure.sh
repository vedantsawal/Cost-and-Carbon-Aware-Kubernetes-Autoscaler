#!/usr/bin/env bash
set -euo pipefail
source ./demo_00_env.sh

# Namespace
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# Minimal RBAC to let our in-cluster job create deployments/services in $NAMESPACE
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scale-burst
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-writer
  namespace: ${NAMESPACE}
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","watch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scale-writer-binding
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: scale-burst
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: scale-writer
  apiGroup: rbac.authorization.k8s.io
---
# PDB to keep 50% of burst pods available during consolidations/rotations
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: burst-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: "50%"
  selector:
    matchLabels:
      group: scale-burst
EOF

# Friendly labels on NodePools (purely for grouping in OpenCost/dashboards)
# These may be no-ops if your cluster doesn't have a 'nodepool' resource.
kubectl label nodepool "${NP_SPOT}" autoscale.strategy=cost carbon.simulated=low --overwrite || true
kubectl label nodepool "${NP_OD}"   autoscale.strategy=slo  carbon.simulated=medium --overwrite || true
