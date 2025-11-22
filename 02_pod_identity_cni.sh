#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_common.sh"

log "Ensure eks-pod-identity-agent add-on"
aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --addon-name eks-pod-identity-agent >/dev/null 2>&1 || \
aws eks create-addon   --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --addon-name eks-pod-identity-agent >/dev/null

ROLE_NAME="AmazonEKSPodIdentityAmazonVPCCNIRole-${CLUSTER_NAME}"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Create IAM role for CNI"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

HAS_ASSOC=$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'associations[?namespace==`kube-system` && serviceAccount==`aws-node`].associationId' \
  --output text 2>/dev/null || true)

if [[ -z "$HAS_ASSOC" ]]; then
  log "Create Pod Identity association for aws-node"
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace kube-system --service-account aws-node --role-arn "$ROLE_ARN" >/dev/null
fi

log "Restart CNI DaemonSet"
kubectl -n kube-system rollout restart ds/aws-node
kubectl -n kube-system rollout status ds/aws-node --timeout=5m
log "Stage 02 OK."
