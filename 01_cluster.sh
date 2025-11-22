#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_common.sh"

: "${SKIP_CLUSTER_CREATE:=false}"
: "${ENABLE_OIDC_AT_CREATE:=false}"   # <-- NEW: default false; IRSA will be added in step 05

WORK="$SCRIPT_DIR/.work"; mkdir -p "$WORK"

log "Render eksctl config (withOIDC=${ENABLE_OIDC_AT_CREATE})"
cat > "$WORK/cluster.yaml" <<CFG
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
iam:
  withOIDC: ${ENABLE_OIDC_AT_CREATE}
vpc:
  subnets:
    private: {}
    public: {}
managedNodeGroups:
  - name: ng-general
    instanceType: ${NODE_TYPE}
    desiredCapacity: ${NODE_DESIRED}
    minSize: ${NODE_MIN}
    maxSize: ${NODE_MAX}
    labels: { role: general }
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        ebs: true
CFG

if [[ "$SKIP_CLUSTER_CREATE" == "true" ]] || aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  log "Cluster exists or SKIP_CLUSTER_CREATE=true; skipping create."
else
  log "Creating EKS cluster ${CLUSTER_NAME} in ${AWS_REGION}…"
  eksctl create cluster -f "$WORK/cluster.yaml"
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
kubectl get nodes -o wide
log "Stage 01 OK."
