#!/usr/bin/env bash
# Common environment for all demo scripts
set -euo pipefail

# --- EDIT if needed ---
export CLUSTER_NAME="${CLUSTER_NAME:-demo3}"
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
export NAMESPACE="${NAMESPACE:-nov-22}"
export NS="${NS:-nov-22}"
export WORKSPACE_ID=ws-6ee86ef2-5fd6-4600-bce0-a22a93ad23d2

export WORKSPACE_ID=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" amp list-workspaces \
 --query "sort_by(workspaces[?alias=='opencost-demo3-us-east-2' && status.statusCode==\`ACTIVE\`], &createdAt)[-1].workspaceId" \
 --output text)

# Karpenter NodePools (you already created these in step 05)
export NP_SPOT="${NP_SPOT:-spot-preferred}"
export NP_OD="${NP_OD:-on-demand-slo}"

# Zones you want to "prefer" in off-peak vs peak profiles
export OFFPEAK_ZONES="${OFFPEAK_ZONES:-us-east-2a}"
export PEAK_ZONES="${PEAK_ZONES:-us-east-2c}"

echo "[Demo 00 environment] Using:"
echo "  CLUSTER_NAME=$CLUSTER_NAME"
echo "  AWS_REGION=$AWS_REGION"
echo "  PROFILE=$AWS_PROFILE"
echo "  NS=$NAMESPACE"
echo "  WORKSPACE_ID=$WORKSPACE_ID"
