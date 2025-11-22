#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/00_common.sh"

### ---------- tiny logger ----------
ts(){ date +"%Y-%m-%dT%H:%M:%S%z"; }
log(){ printf "[INFO] %s %s\n" "$(ts)" "$*" >&2; }
warn(){ printf "[WARN] %s %s\n" "$(ts)" "$*" >&2; }
err(){ printf "[ERR ] %s %s\n" "$(ts)" "$*" >&2; }
err_report(){ local ec=$?; err "Failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND} (exit $ec)"; exit $ec; }
trap err_report ERR

### ---------- inputs ----------
: "${AWS_REGION:?Set AWS_REGION}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
AWS_PROFILE="${AWS_PROFILE:-default}"

NS="karpenter"
CTRL_RELEASE="karpenter"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.1}"   # accepts 1.8.1 or v1.8.1
CHART_VER="${KARPENTER_VERSION#v}"                # 1.8.1

### ---------- aws helpers ----------
aws(){ command aws --region "$AWS_REGION" --profile "$AWS_PROFILE" "$@"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER_EP="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.endpoint' --output text)"

log "Using → CLUSTER_NAME=$CLUSTER_NAME  AWS_REGION=$AWS_REGION  AWS_PROFILE=$AWS_PROFILE"
log "Cluster endpoint: $CLUSTER_EP"

### ---------- IAM: node role & instance profile ----------
NODE_ROLE="KarpenterNodeRole-${CLUSTER_NAME}"
NODE_INSTANCE_PROFILE="KarpenterNodeInstanceProfile-${CLUSTER_NAME}"

if ! aws iam get-role --role-name "$NODE_ROLE" >/dev/null 2>&1; then
  log "Creating node role: $NODE_ROLE"
  aws iam create-role --role-name "$NODE_ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
  aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
else
  log "Node role exists: $NODE_ROLE"
fi

if ! aws iam get-instance-profile --instance-profile-name "$NODE_INSTANCE_PROFILE" >/dev/null 2>&1; then
  log "Creating instance profile: $NODE_INSTANCE_PROFILE"
  aws iam create-instance-profile --instance-profile-name "$NODE_INSTANCE_PROFILE"
  aws iam add-role-to-instance-profile --instance-profile-name "$NODE_INSTANCE_PROFILE" --role-name "$NODE_ROLE"
else
  log "Instance profile exists: $NODE_INSTANCE_PROFILE"
fi

### ---------- IAM: controller policy & role ----------
CTRL_POLICY="KarpenterControllerPolicy-${CLUSTER_NAME}"
CTRL_ROLE="KarpenterControllerRole-${CLUSTER_NAME}"
POLICY_DOC="$(cat <<'JSON'
{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":"*"},
    {"Effect":"Allow","Action":["iam:PassRole"],"Resource":"*","Condition":{"StringEquals":{"iam:PassedToService":"ec2.amazonaws.com"}}},
    {"Effect":"Allow","Action":[
      "ec2:CreateLaunchTemplate","ec2:DeleteLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion","ec2:DeleteLaunchTemplateVersions",
      "ec2:DescribeLaunchTemplates","ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages","ec2:DescribeInstances","ec2:RunInstances","ec2:TerminateInstances",
      "ec2:GetInstanceTypesFromInstanceRequirements","ec2:DescribeInstanceTypes","ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones","ec2:DescribeSubnets","ec2:DescribeSecurityGroups","ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAccountAttributes","ec2:DescribeSpotPriceHistory",
      "ec2:CreateTags","ec2:DeleteTags",
      "ec2:CreateFleet","ec2:DeleteFleets","ec2:DescribeFleets","ec2:DescribeFleetInstances","ec2:DescribeFleetHistory"
    ],"Resource":"*"},
    {"Effect":"Allow","Action":["pricing:GetProducts"],"Resource":"*"},
    {"Effect":"Allow","Action":[
      "iam:ListInstanceProfiles","iam:GetInstanceProfile",
      "iam:CreateInstanceProfile","iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile","iam:UntagInstanceProfile",
      "iam:CreateServiceLinkedRole"
    ],"Resource":"*",
     "Condition":{"StringEqualsIfExists":{"iam:AWSServiceName":"spot.amazonaws.com"}}},
    {"Effect":"Allow","Action":["eks:DescribeCluster"],"Resource":"*"}
  ]
}
JSON
)"

if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CTRL_POLICY}" >/dev/null 2>&1; then
  log "Controller policy exists; updating: ${CTRL_POLICY}"
  aws iam create-policy-version --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CTRL_POLICY}" \
      --policy-document "$POLICY_DOC" --set-as-default >/dev/null
else
  log "Creating controller policy: ${CTRL_POLICY}"
  aws iam create-policy --policy-name "${CTRL_POLICY}" --policy-document "$POLICY_DOC" >/dev/null
fi

TRUST_DOC="$(cat <<JSON
{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Federated":"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text | sed -e 's#^https://##')"},
    "Action":"sts:AssumeRoleWithWebIdentity",
    "Condition":{"StringEquals":{"$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text | sed -e 's#^https://##'):sub":"system:serviceaccount:${NS}:karpenter"}}
  }]
}
JSON
)"

if ! aws iam get-role --role-name "$CTRL_ROLE" >/dev/null 2>&1; then
  log "Creating controller role: ${CTRL_ROLE}"
  aws iam create-role --role-name "${CTRL_ROLE}" --assume-role-policy-document "$TRUST_DOC" >/dev/null
  aws iam attach-role-policy --role-name "${CTRL_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CTRL_POLICY}" >/dev/null
else
  log "Controller role exists: ${CTRL_ROLE}"
  # ensure policy attached
  aws iam attach-role-policy --role-name "${CTRL_ROLE}" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CTRL_POLICY}" >/dev/null || true
fi

CTRL_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CTRL_ROLE}"

### ---------- Helm install (OCI) ----------
log "Installing/Upgrading Karpenter (OCI ${CHART_VER})…"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

# Best-effort logout before pulling from public ECR
helm registry logout public.ecr.aws >/dev/null 2>&1 || true

helm -n "$NS" upgrade --install "$CTRL_RELEASE" oci://public.ecr.aws/karpenter/karpenter \
  --version "${CHART_VER}" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$CTRL_ROLE_ARN" \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set settings.clusterEndpoint="$CLUSTER_EP" \
  --set settings.interruptionQueue="" \
  --set logs.level=info

### ---------- Post-install sanity ----------
log "Waiting for controller deployment…"
kubectl -n "$NS" rollout status deploy/karpenter --timeout=2m || true

log "Installed resources:"
kubectl -n "$NS" get deploy,po
echo
kubectl get crd | grep -E 'karpenter|nodepool|ec2nodeclass' || true
echo
log "Done."
