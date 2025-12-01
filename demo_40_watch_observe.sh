#!/usr/bin/env bash
# demo_40_watch_observe.sh
# - Resolves WORKSPACE_ID from env or opencost/adot-config
# - Kills stale PFs; starts Grafana, OpenCost, and AMP proxy PFs
# - Runs a quick AMP health query

set -euo pipefail
source ./demo_00_env.sh

# Workload/demo namespace
ns="${NAMESPACE:-nov-22}"

# Grafana (from kube-prometheus-stack)
grafana_ns="${GRAFANA_NS:-monitoring}"

# AMP SigV4 proxy + ADOT config (installed with OpenCost)
proxy_ns="${PROXY_NS:-opencost}"

echo "[Obs 40] Namespace=${ns}"

# Resolve WORKSPACE_ID
WS="${WORKSPACE_ID:-${WS:-}}"
if [[ -z "${WS}" || "${WS}" == "None" ]]; then
  if kubectl -n opencost get cm adot-config >/dev/null 2>&1; then
    WS="$(kubectl -n opencost get cm adot-config -o jsonpath='{.data.collector\.yaml}' \
      | grep -Eo 'workspaces/[A-Za-z0-9-]+' | head -n1 | cut -d/ -f2 || true)"
  fi
fi
if [[ -z "${WS}" || "${WS}" == "None" ]]; then
  echo "(WORKSPACE_ID not set and could not auto-detect from opencost/adot-config)"
  echo "Set it and rerun, e.g.:"
  echo "  export WORKSPACE_ID=\$(aws --profile \"$PROFILE\" --region \"$AWS_REGION\" amp list-workspaces --query \"workspaces[?status.statusCode=='ACTIVE']|[-1].workspaceId\" --output text)"
else
  echo "[Obs 40] Using AMP WORKSPACE_ID=${WS}"
fi

echo
echo "# Grafana pod status"
kubectl -n "${ns}" get deploy grafana || true
kubectl -n "${ns}" get pods -l app=grafana -o wide || true
echo

echo "# Grafana admin credentials"
user="$(kubectl -n "${ns}" get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 --decode || true)"
pass="$(kubectl -n "${ns}" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode || true)"
echo "user: ${user:-admin}"
echo "pass: ${pass:-<secret>}"

# Kill any stale PFs
kill_port() { lsof -ti tcp:$1 | xargs -r kill -9 >/dev/null 2>&1 || true; }
echo
echo "# Port-forward local endpoints"
kill_port 3000; kill_port 9090; kill_port 8005

# Grafana
kubectl -n "${ns}" port-forward svc/grafana 3000:3000 >/tmp/grafana_pf.log 2>&1 &
echo "Grafana => http://127.0.0.1:3000  (logs: /tmp/grafana_pf.log)  [user=${user:-admin}]"

# OpenCost
if kubectl -n opencost get svc opencost >/dev/null 2>&1; then
  kubectl -n opencost port-forward svc/opencost 9090:9090 >/tmp/opencost_pf.log 2>&1 &
  echo "OpenCost UI => http://127.0.0.1:9090  (logs: /tmp/opencost_pf.log)"
elif kubectl -n opencost get svc opencost-ui >/dev/null 2>&1; then
  kubectl -n opencost port-forward svc/opencost-ui 9090:9090 >/tmp/opencost_pf.log 2>&1 &
  echo "OpenCost UI => http://127.0.0.1:9090  (logs: /tmp/opencost_pf.log)"
else
  echo "(OpenCost UI service not found in namespace 'opencost')"
fi

# === AMP proxy / quick queries ===
# The AMP SigV4 proxy is deployed with OpenCost (namespace: opencost)
PROXY_NS="${PROXY_NS:-opencost}"

echo
echo "# AMP proxy (namespace: ${PROXY_NS})"
kubectl -n "${PROXY_NS}" rollout status deploy/amp-sigv4-proxy --timeout=120s || {
  echo "⚠️ amp-sigv4-proxy not ready in namespace ${PROXY_NS}"; exit 1; }

# Derive WORKSPACE_ID from the ADOT config in the same namespace
WORKSPACE_ID="${WORKSPACE_ID:-$(
  kubectl -n "${PROXY_NS}" get cm adot-config -o jsonpath='{.data.collector\.yaml}' \
    | grep -Eo 'workspaces/[A-Za-z0-9-]+' | head -n1 | cut -d/ -f2
)}"
echo "Using AMP WORKSPACE_ID=${WORKSPACE_ID}"

# Clean up old PFs on 8005 if any
pkill -f 'kubectl.*port-forward.*8005:8005' 2>/dev/null || true

# Start PF
kubectl -n "${PROXY_NS}" port-forward svc/amp-sigv4-proxy 8005:8005 >/tmp/amp_pf.log 2>&1 & AMP_PF=$!

# Wait for the local socket to be ready
for i in {1..20}; do
  (echo > /dev/tcp/127.0.0.1/8005) >/dev/null 2>&1 && break
  sleep 0.3
done

echo
echo "AMP proxy => http://127.0.0.1:8005/workspaces/${WORKSPACE_ID}/api/v1/query  (logs: /tmp/amp_pf.log)"
echo "== /tmp/amp_pf.log =="
tail -n +1 /tmp/amp_pf.log || true

# Quick tests
echo
echo "# Quick test against AMP (metric names)"
curl -sS "http://127.0.0.1:8005/workspaces/${WORKSPACE_ID}/api/v1/label/__name__/values" | head -c 400; echo

echo
echo "# Quick test against AMP (up)"
curl -sS "http://127.0.0.1:8005/workspaces/${WORKSPACE_ID}/api/v1/query?query=up" | head -c 400; echo
