#!/usr/bin/env bash
# 06_opencost.sh — Deploy SigV4 proxy, ADOT → AMP, (optional) OpenCost
# Idempotent; safe to re-run. Requires: aws, kubectl, helm
set -Eeuo pipefail
source "$(dirname "$0")/00_common.sh"

# avoid history expansion surprises with $!
set +H

# ========= Config =========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${SCRIPT_DIR}/00_common.sh" ]] && source "${SCRIPT_DIR}/00_common.sh" || true

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${AWS_PROFILE:=default}"

# Tunables
: "${NAMESPACE:=opencost}"
: "${AMP_ALIAS_PREFIX:=opencost}"
: "${AMP_PROXY_NAME:=amp-sigv4-proxy}"
: "${AMP_PROXY_PORT:=8005}"
: "${ADOT_DEPLOY_NAME:=adot-collector}"
: "${KSM_RELEASE:=kube-state-metrics}"
: "${OPENCOST_RELEASE:=opencost}"

# Charts
: "${OPENCOST_CHART:=opencost/opencost}"
: "${OPENCOST_CHART_VERSION:=2.4.0}"
: "${KSM_CHART:=prometheus-community/kube-state-metrics}"

# Security (PSA:restricted-friendly)
: "${NONROOT_UID:=65532}"
: "${NONROOT_GID:=65532}"

# ========= Helpers =========
log(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*"; }
err(){ echo -e "[ERR ] $*" >&2; }

need(){ command -v "$1" >/dev/null || { err "Missing dependency: $1"; exit 1; }; }

err_report(){ err "Failed at line $1"; exit 1; }
trap 'err_report $LINENO' ERR

amp_wait_active() {
  local id="$1" region="$2" tries="${3:-120}"
  log "Waiting for AMP workspace ${id} to become ACTIVE…"
  local st=""
  for ((i=1; i<=tries; i++)); do
    st="$(aws amp describe-workspace --workspace-id "$id" --region "$region" \
         --query 'workspace.status.statusCode' --output text 2>/dev/null || echo "")"
    if [[ "$st" == "ACTIVE" ]]; then
      log "AMP workspace ${id} is ACTIVE"
      return 0
    fi
    [[ -z "$st" || "$st" == "CREATING" ]] || warn "AMP status: ${st} (attempt ${i}/${tries})"
    sleep 5
  done
  err "AMP workspace ${id} did not become ACTIVE (last status: ${st:-unknown})."
}

create_or_update_trust() {
  # $1 role name, $2 sa ns, $3 sa name
  local role="$1" sa_ns="$2" sa_name="$3"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Federated":"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"},
    "Action":"sts:AssumeRoleWithWebIdentity",
    "Condition":{"StringEquals":{
      "${OIDC_PROVIDER}:aud":"sts.amazonaws.com",
      "${OIDC_PROVIDER}:sub":"system:serviceaccount:${sa_ns}:${sa_name}"
    }}
  }]
}
EOF
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$role" --policy-document "file://${tmp}" >/dev/null
  else
    aws iam create-role --role-name "$role" --assume-role-policy-document "file://${tmp}" >/dev/null
  fi
  rm -f "$tmp"
}

rollout_with_rescue() {
  local ns="$1" kind="$2" name="$3" label="$4"
  if ! kubectl -n "$ns" rollout status "$kind/$name" --timeout=5m; then
    warn "Rollout timed out for $kind/$name — attempting rescue (scale 0 → 1)…"
    kubectl -n "$ns" scale "$kind/$name" --replicas=0 || true
    kubectl -n "$ns" wait --for=delete pod -l "$label" --timeout=180s || true
    kubectl -n "$ns" scale "$kind/$name" --replicas=1
    kubectl -n "$ns" rollout status "$kind/$name" --timeout=5m
  fi
}

# Try a port-forward on first free port among a small set
_pf_start() {
  local ns="$1" svc="$2" rport="$3"
  local candidates=("8005" "18005" "28005")
  for lp in "${candidates[@]}"; do
    if ! ( : > /dev/tcp/127.0.0.1/"$lp" ) >/dev/null 2>&1; then
      kubectl -n "$ns" port-forward "svc/${svc}" "${lp}:${rport}" >/tmp/oc_pf.log 2>&1 &
      PF_PID=$!
      sleep 1
      if ps -p "$PF_PID" >/dev/null 2>&1; then
        PF_LOCAL_PORT="$lp"
        return 0
      fi
    fi
  done
  return 1
}

probe_amp_has_data() {
  # Returns 0 if AMP 'label/__name__/values' returns anything non-empty
  local ns="$1" workspace_id="$2" proxy_svc="$3" proxy_port="$4"
  local PF_PID= PF_LOCAL_PORT=
  _pf_start "$ns" "$proxy_svc" "$proxy_port" || { warn "port-forward failed; see /tmp/oc_pf.log"; return 1; }
  # wait a bit for listener
  for _ in {1..50}; do ( : > /dev/tcp/127.0.0.1/"$PF_LOCAL_PORT" ) >/dev/null 2>&1 && break; sleep 0.1; done
  local url="http://127.0.0.1:${PF_LOCAL_PORT}/workspaces/${workspace_id}/api/v1/label/__name__/values"
  local ok=1
  for _ in {1..6}; do
    if curl -sS --connect-timeout 3 "$url" | grep -Fq '"data":['; then ok=0; break; fi
    sleep 5
  done
  kill "$PF_PID" >/dev/null 2>&1 || true
  return $ok
}

# ========= Main =========
main() {
  need aws; need kubectl; need helm
  aws sts get-caller-identity >/dev/null 2>&1 || { err "AWS CLI not authenticated"; }

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.identity.oidc.issuer' --output text)"
  [[ "$OIDC_ISSUER" == https://* ]] || { err "Cluster has no OIDC issuer"; }
  OIDC_PROVIDER="${OIDC_ISSUER#https://}"

  log "Using → CLUSTER_NAME=${CLUSTER_NAME}  AWS_REGION=${AWS_REGION}  AWS_PROFILE=${AWS_PROFILE}"

  # 0) Namespace & repos
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
  helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null || true

  # 1) AMP workspace
  AMP_ALIAS="${AMP_ALIAS_PREFIX}-${CLUSTER_NAME}-${AWS_REGION}"
  log "No AMP_WORKSPACE_ID provided; searching for alias '${AMP_ALIAS}'…"
  AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-$(aws amp list-workspaces --region "$AWS_REGION" \
    --query "workspaces[?alias=='${AMP_ALIAS}']|[0].id" --output text 2>/dev/null || echo "")}"
  if [[ -z "$AMP_WORKSPACE_ID" || "$AMP_WORKSPACE_ID" == "None" ]]; then
    log "Creating AMP workspace with alias '${AMP_ALIAS}'"
    AMP_WORKSPACE_ID="$(aws amp create-workspace --region "$AWS_REGION" --alias "$AMP_ALIAS" \
      --query workspaceId --output text)"
  fi
  amp_wait_active "$AMP_WORKSPACE_ID" "$AWS_REGION" 120

  # 2) IAM roles (IRSA): Query + RemoteWrite (+ precise inline policy)
  QUERY_ROLE="OpenCostAMPQueryRole-${CLUSTER_NAME}"
  WRITER_ROLE="AMPRemoteWriteRole-${CLUSTER_NAME}"

  create_or_update_trust "$QUERY_ROLE" "$NAMESPACE" "$AMP_PROXY_NAME"
  aws iam attach-role-policy --role-name "$QUERY_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess >/dev/null 2>&1 || true

  # Inline policy for this workspace (Query + Describe)
  cat > /tmp/amp-query-inline.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:DescribeWorkspace"
    ],
    "Resource": "arn:aws:aps:${AWS_REGION}:${ACCOUNT_ID}:workspace/${AMP_WORKSPACE_ID}"
  }]
}
EOF
  aws iam put-role-policy \
    --role-name "$QUERY_ROLE" \
    --policy-name "AMPQueryWorkspaceAccess-${AMP_WORKSPACE_ID}" \
    --policy-document file:///tmp/amp-query-inline.json >/dev/null

  create_or_update_trust "$WRITER_ROLE" "$NAMESPACE" "$ADOT_DEPLOY_NAME"
  aws iam attach-role-policy --role-name "$WRITER_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess >/dev/null 2>&1 || true

  QUERY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${QUERY_ROLE}"
  WRITER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${WRITER_ROLE}"

  # 3) SigV4 proxy (non-root; minimal caps)
  log "Deploying SigV4 proxy (${AMP_PROXY_NAME})…"
  kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AMP_PROXY_NAME}
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${QUERY_ROLE_ARN}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${AMP_PROXY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: ${AMP_PROXY_NAME} } }
  template:
    metadata:
      labels: { app: ${AMP_PROXY_NAME} }
    spec:
      serviceAccountName: ${AMP_PROXY_NAME}
      terminationGracePeriodSeconds: 10
      securityContext:
        runAsNonRoot: true
        runAsUser: ${NONROOT_UID}
        runAsGroup: ${NONROOT_GID}
        fsGroup: ${NONROOT_GID}
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: aws-sigv4-proxy
        image: public.ecr.aws/aws-observability/aws-sigv4-proxy:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
        args:
          - --name=aps
          - --region=${AWS_REGION}
          - --host=aps-workspaces.${AWS_REGION}.amazonaws.com
          - --port=:${AMP_PROXY_PORT}
        ports:
          - containerPort: ${AMP_PROXY_PORT}
        resources:
          requests: { cpu: "100m", memory: "128Mi" }
          limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: ${AMP_PROXY_NAME}
  namespace: ${NAMESPACE}
spec:
  selector: { app: ${AMP_PROXY_NAME} }
  ports:
    - name: http
      port: ${AMP_PROXY_PORT}
      targetPort: ${AMP_PROXY_PORT}
      protocol: TCP
EOF
  rollout_with_rescue "$NAMESPACE" deploy "$AMP_PROXY_NAME" "app=${AMP_PROXY_NAME}"

  # 4) kube-state-metrics (needed as a known-good scrape target)
  log "Installing kube-state-metrics…"
  helm upgrade --install "${KSM_RELEASE}" "${KSM_CHART}" -n "$NAMESPACE" \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=256Mi

  # 5) ADOT RBAC for Kubernetes SD (nodes/services/endpoints/pods)
  log "Applying ADOT RBAC…"
  kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: adot-collector-k8ssd
rules:
- apiGroups: [""]
  resources: ["nodes","nodes/proxy","services","endpoints","pods","namespaces"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: adot-collector-k8ssd-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: adot-collector-k8ssd
subjects:
- kind: ServiceAccount
  name: adot-collector
  namespace: opencost
EOF

  # 6) ADOT collector: scrape KSM statically → remote_write AMP (SigV4)
  log "Deploying ADOT collector…"
  kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ADOT_DEPLOY_NAME}
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: ${WRITER_ROLE_ARN}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: adot-config
  namespace: ${NAMESPACE}
data:
  collector.yaml: |
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 30s
          scrape_configs:
          - job_name: ksm-static
            static_configs:
            - targets: ["kube-state-metrics.${NAMESPACE}.svc.cluster.local:8080"]
    exporters:
      prometheusremotewrite:
        endpoint: https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write
        auth:
          authenticator: sigv4auth
    extensions:
      sigv4auth:
        region: ${AWS_REGION}
    service:
      extensions: [sigv4auth]
      pipelines:
        metrics:
          receivers: [prometheus]
          exporters: [prometheusremotewrite]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ADOT_DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector: { matchLabels: { app: ${ADOT_DEPLOY_NAME} } }
  template:
    metadata:
      labels: { app: ${ADOT_DEPLOY_NAME} }
    spec:
      serviceAccountName: ${ADOT_DEPLOY_NAME}
      terminationGracePeriodSeconds: 10
      securityContext:
        runAsNonRoot: true
        runAsUser: ${NONROOT_UID}
        runAsGroup: ${NONROOT_GID}
        fsGroup: ${NONROOT_GID}
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: adot
        image: public.ecr.aws/aws-observability/aws-otel-collector:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
        args: ["--config=/conf/collector.yaml"]
        volumeMounts:
        - name: conf
          mountPath: /conf
        ports:
        - containerPort: 4317
        - containerPort: 55680
        resources:
          requests: { cpu: "200m", memory: "256Mi" }
          limits:   { cpu: "1", memory: "512Mi" }
      volumes:
      - name: conf
        configMap:
          name: adot-config
          items:
          - key: collector.yaml
            path: collector.yaml
EOF
  rollout_with_rescue "$NAMESPACE" deploy "$ADOT_DEPLOY_NAME" "app=${ADOT_DEPLOY_NAME}"

  # 7) Probe AMP for data through the proxy (non-blocking)
  log "Probing AMP for metrics (label names)…"
  if probe_amp_has_data "$NAMESPACE" "$AMP_WORKSPACE_ID" "$AMP_PROXY_NAME" "$AMP_PROXY_PORT"; then
    log "AMP is receiving metrics 🎉"
  else
    warn "AMP still looks empty; ADOT may need a minute after rollout."
  fi

  # 8) (Optional) Install/Upgrade OpenCost — can skip with SKIP_OPEN_COST=1
  if [[ "${SKIP_OPEN_COST:-0}" == "1" ]]; then
    log "Skipping OpenCost install/upgrade (SKIP_OPEN_COST=1)."
  else
    log "Installing/Upgrading OpenCost…"
    # Render values to satisfy policies and select external Prometheus (AMP via proxy)
    cat > /tmp/opencost-values.yaml <<EOF
opencost:
  cloudProvider: AWS
  exporter:
    defaultClusterId: ${CLUSTER_NAME}
    resources:
      requests: { cpu: 200m, memory: 256Mi }
      limits:   { cpu: 1000m, memory: 1Gi }
  # Some chart revs also read exporter resources from this flat key; set both to appease policies.
  resources:
    requests: { cpu: 200m, memory: 256Mi }
    limits:   { cpu: 1000m, memory: 1Gi }
  ui:
    enabled: true
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 500m, memory: 256Mi }
  prometheus:
    internal:
      enabled: false
    external:
      enabled: true
      url: "http://${AMP_PROXY_NAME}.${NAMESPACE}.svc.cluster.local:${AMP_PROXY_PORT}/workspaces/${AMP_WORKSPACE_ID}"
    amp:
      enabled: false
EOF
    helm upgrade --install "${OPENCOST_RELEASE}" "${OPENCOST_CHART}" -n "${NAMESPACE}" \
      --version "${OPENCOST_CHART_VERSION}" \
      -f /tmp/opencost-values.yaml

    rollout_with_rescue "$NAMESPACE" deploy "$OPENCOST_RELEASE" "app.kubernetes.io/name=opencost"

    log "UI: kubectl -n ${NAMESPACE} port-forward svc/${OPENCOST_RELEASE} 9090:9090"
    echo "    http://localhost:9090"
  fi

  echo
  log "AMP workspace: ${AMP_WORKSPACE_ID}   (region: ${AWS_REGION})"
  log "Done."
}

main "$@"
