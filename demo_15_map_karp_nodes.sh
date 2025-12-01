#!/usr/bin/env bash
set -Eeuo pipefail

# Load the same env the demo scripts use
source "$(dirname "$0")/demo_00_env.sh"

# Be forgiving: PROFILE may not be set; prefer AWS_PROFILE, else default
AWS_PROFILE="${AWS_PROFILE:-${PROFILE:-default}}"
PROFILE="${PROFILE:-$AWS_PROFILE}"

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:?AWS_REGION is required}"

log(){ echo -e "[Demo 15] $*"; }
err(){ echo -e "[Demo 15] ERROR: $*" >&2; exit 1; }

log "Ensuring aws-auth contains Karpenter node role mapping…"
log "Cluster=${CLUSTER_NAME}  Region=${AWS_REGION}  Profile=${PROFILE}"

# Karpenter node role name (created by 05_karpenter.sh)
NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"

# Look up its ARN
if ! NODE_ROLE_ARN="$(aws iam get-role --role-name "$NODE_ROLE_NAME" \
      --query 'Role.Arn' --output text 2>/dev/null)"; then
  err "Could not find IAM role ${NODE_ROLE_NAME}. Run 05_karpenter.sh first."
fi
[[ -n "$NODE_ROLE_ARN" && "$NODE_ROLE_ARN" != "None" ]] || err "Empty ARN for ${NODE_ROLE_NAME}"

log "Node role ARN = ${NODE_ROLE_ARN}"

# Quick check
if kubectl -n kube-system get configmap aws-auth -o yaml | grep -q "$NODE_ROLE_ARN"; then
  echo "✅ aws-auth already contains mapping for ${NODE_ROLE_ARN}"
  exit 0
fi

# If eksctl is present, use identity mapping (simplest + idempotent)
if command -v eksctl >/dev/null 2>&1; then
  log "Using eksctl to create/ensure iamidentitymapping…"
  eksctl create iamidentitymapping \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --arn "$NODE_ROLE_ARN" \
    --username "system:node:{{EC2PrivateDNSName}}" \
    --group system:bootstrappers \
    --group system:nodes >/dev/null 2>&1 || true
else
  # Fallback: patch aws-auth ConfigMap if eksctl is unavailable
  log "eksctl not found; patching aws-auth directly…"
  TMP="$(mktemp)"
  kubectl -n kube-system get cm aws-auth -o yaml > "$TMP"

  if ! grep -qF "rolearn: ${NODE_ROLE_ARN}" "$TMP"; then
    # Append a new mapRoles entry
    awk -v ARN="$NODE_ROLE_ARN" '
      BEGIN{added=0}
      {print}
      /mapRoles: *\|/ && added==0 {
        print "    - rolearn: " ARN
        print "      username: system:node:{{EC2PrivateDNSName}}"
        print "      groups:"
        print "      - system:bootstrappers"
        print "      - system:nodes"
        added=1
      }
    ' "$TMP" | kubectl -n kube-system apply -f -
  else
    log "aws-auth already contains mapping for ${NODE_ROLE_ARN}; skipping."
  fi
  rm -f "$TMP"
fi

# Show the effective aws-auth snippet for sanity
log "aws-auth mapRoles snippet:"
kubectl -n kube-system get cm aws-auth -o jsonpath='{.data.mapRoles}' | sed 's/^/[aws-auth] /'


# Verify
if kubectl -n kube-system get configmap aws-auth -o yaml | grep -q "$NODE_ROLE_ARN"; then
  echo "✅ Mapping present for ${NODE_ROLE_ARN}"
else
  echo "❌ Mapping still missing. Try re-running this script, or run the eksctl command manually."
  exit 1
fi

