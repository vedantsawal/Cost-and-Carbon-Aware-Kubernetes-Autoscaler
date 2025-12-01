#!/usr/bin/env bash
# demo_18_preroll_check.sh
# Pre-roll sanity before recording: confirm environment, clean state, and neutral NodePools.

set -euo pipefail

if [[ -f "./demo_00_env.sh" ]]; then
  # shellcheck disable=SC1091
  source ./demo_00_env.sh
fi

: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${NS:=nov-22}"
: "${NAMESPACE:=${NS}}"
: "${NP_SPOT:=spot-preferred}"
: "${NP_OD:=on-demand-slo}"

echo "[Pre-roll 18] Cluster=${CLUSTER_NAME}  Region=${AWS_REGION}  Namespace=${NAMESPACE}"
echo "[Pre-roll 18] Checking prerequisites..."

# A. Namespace exists
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ Namespace ${NAMESPACE} does not exist. Run demo_10_setup_configure.sh first."
  exit 1
fi
echo "✅ Namespace ${NAMESPACE} exists."

# B. Burst workloads absent
echo "[Check] No active burst deployments or pods..."
DEPLOY_COUNT=$(kubectl -n "${NAMESPACE}" get deploy -l group=scale-burst --no-headers 2>/dev/null | wc -l | tr -d ' ')
POD_COUNT=$(kubectl -n "${NAMESPACE}" get pods -l group=scale-burst --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DEPLOY_COUNT" -eq 0 && "$POD_COUNT" -eq 0 ]]; then
  echo "✅ No burst workloads found."
else
  echo "⚠️ Found $DEPLOY_COUNT deployments and $POD_COUNT pods labeled group=scale-burst."
  echo "   Run ./demo_19_reset_policies.sh to remove them."
  exit 1
fi

# C. NodePools neutral
echo "[Check] NodePools have neutral disruption and requirements..."
for NP in "${NP_SPOT}" "${NP_OD}"; do
  if ! kubectl get nodepool "$NP" >/dev/null 2>&1; then
    echo "❌ NodePool $NP missing."
    exit 1
  fi
  CONSOLIDATION=$(kubectl get nodepool "$NP" -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null || echo "missing")
  if [[ "$CONSOLIDATION" == "WhenEmpty" ]]; then
    echo "✅ $NP consolidationPolicy=$CONSOLIDATION"
  else
    echo "⚠️ $NP consolidationPolicy=$CONSOLIDATION (expected WhenEmpty). Run reset."
    exit 1
  fi
done

# D. Port-forward processes check
echo "[Check] No old port-forwards on 3000, 8005, 9090..."
for PORT in 3000 8005 9090; do
  if lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "⚠️ Port $PORT is already in use. Kill old PFs before starting."
    exit 1
  fi
done
echo "✅ No port-forwards running."

echo "[Check] aws-auth has Karpenter node role mapping..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"

if kubectl -n kube-system get configmap aws-auth -o yaml \
  | grep -q "$NODE_ROLE_ARN"; then
  echo "✅ aws-auth contains $NODE_ROLE_ARN"
else
  echo "⚠️  aws-auth is missing $NODE_ROLE_ARN"
  echo "    Run:"
  echo "      eksctl create iamidentitymapping --cluster $CLUSTER_NAME --region $AWS_REGION \\"
  echo "        --arn $NODE_ROLE_ARN --username 'system:node:{{EC2PrivateDNSName}}' \\"
  echo "        --group system:bootstrappers --group system:nodes"
  exit 1
fi

echo
echo "[Pre-roll 18] ✅ All good. You can start running:"
echo "   ./demo_20_offpeak_configure.sh"
echo "   ./demo_21_peak_configure.sh"
echo "   ./demo_30_burst_configure.sh"
