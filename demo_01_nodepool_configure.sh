#!/usr/bin/env bash
# demo_01_nodepool_configure_fixed.sh
# Karpenter v1: EC2NodeClass + two NodePools
set -euo pipefail

if [[ -f "./demo_00_env.sh" ]]; then
  # shellcheck disable=SC1091
  source ./demo_00_env.sh
fi

: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${AWS_REGION:?Set AWS_REGION}"

: "${AWS_PROFILE:=default}"
: "${NP_SPOT:=spot-preferred}"
: "${NP_OD:=on-demand-slo}"
: "${NODE_ROLE:=KarpenterNodeRole-${CLUSTER_NAME}}"
: "${EC2_AMI_ALIAS:=bottlerocket@latest}"
: "${NODE_EXPIRE_AFTER:=720h}"
: "${CONSOLIDATE_AFTER:=30s}"

echo "[NodePools] Using: CLUSTER_NAME=${CLUSTER_NAME}  AWS_REGION=${AWS_REGION}  AWS_PROFILE=${AWS_PROFILE}"
echo "[NodePools] Names: EC2NodeClass=default-ec2  NP_SPOT=${NP_SPOT}  NP_OD=${NP_OD}"
echo "[NodePools] IAM Node Role: ${NODE_ROLE}"
echo "[NodePools] AMI alias: ${EC2_AMI_ALIAS}"
echo "[NodePools] Node expireAfter: ${NODE_EXPIRE_AFTER}"
echo "[NodePools] Disruption consolidateAfter: ${CONSOLIDATE_AFTER}"

wait_for() {
  local desc="$1"; shift
  local timeout="$1"; shift
  local start ts
  start=$(date +%s)
  echo "[wait] ${desc} (timeout: ${timeout}s)"
  while true; do
    if "$@" >/dev/null 2>&1; then
      echo "[wait] OK: ${desc}"
      return 0
    fi
    ts=$(date +%s)
    if (( ts - start >= timeout )); then
      echo "[wait] TIMEOUT after ${timeout}s: ${desc}"
      return 1
    fi
    sleep 2
  done
}

echo "[Sanity] kubectl context: $(kubectl config current-context || true)"

kubectl get crd ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 || { echo "Missing CRD ec2nodeclasses.karpenter.k8s.aws"; exit 1; }
kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1 || { echo "Missing CRD nodepools.karpenter.sh"; exit 1; }

wait_for "API discovery lists ec2nodeclasses" 60 bash -lc "kubectl api-resources --cached=false | grep -q '^ec2nodeclasses'"
wait_for "API discovery lists nodepools"      60 bash -lc "kubectl api-resources --cached=false | grep -q '^nodepools'"

# EC2NodeClass
cat <<'EOF' | sed "s|__NODE_ROLE__|${NODE_ROLE}|g; s|__CLUSTER_NAME__|${CLUSTER_NAME}|g; s|__EC2_AMI_ALIAS__|${EC2_AMI_ALIAS}|g" | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default-ec2
spec:
  amiSelectorTerms:
    - alias: __EC2_AMI_ALIAS__
  role: __NODE_ROLE__
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/__CLUSTER_NAME__: owned
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: __CLUSTER_NAME__
  detailedMonitoring: false
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
        encrypted: true
EOF

# SPOT NodePool
cat <<'EOF' | sed "s|__NP_NAME__|${NP_SPOT}|g; s|__NODE_EXPIRE_AFTER__|${NODE_EXPIRE_AFTER}|g; s|__CONSOLIDATE_AFTER__|${CONSOLIDATE_AFTER}|g" | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: __NP_NAME__
  labels:
    autoscale.strategy: cost
    carbon.simulated: low
spec:
  template:
    metadata:
      labels:
        node.kubernetes.io/lifecycle: spot
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default-ec2
      expireAfter: __NODE_EXPIRE_AFTER__
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["c","m","r"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: __CONSOLIDATE_AFTER__
EOF

# ON-DEMAND NodePool
cat <<'EOF' | sed "s|__NP_NAME__|${NP_OD}|g; s|__NODE_EXPIRE_AFTER__|${NODE_EXPIRE_AFTER}|g; s|__CONSOLIDATE_AFTER__|${CONSOLIDATE_AFTER}|g" | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: __NP_NAME__
  labels:
    autoscale.strategy: slo
    carbon.simulated: medium
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default-ec2
      expireAfter: __NODE_EXPIRE_AFTER__
      requirements:
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["c","m","r"]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["on-demand"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: __CONSOLIDATE_AFTER__
EOF

echo "[Verify] Listing resources…"
kubectl get ec2nodeclass
kubectl get nodepool -o wide
