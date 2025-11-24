\
#!/usr/bin/env bash
# demo_40_watch_observe.sh (v2)
# - Robust to missing WORKSPACE_ID (uses WS, or tries to read from amp-sigv4-proxy env)
# - Skips AMP port-forward if no workspace id is available, but still runs Grafana/OpenCost PFs
# - Prints clear next steps to set WORKSPACE_ID

set -euo pipefail
source ./demo_00_env.sh

export NAMESPACE="${NAMESPACE:-nov-22}"
export NS="${NS:-nov-22}"
export WORKSPACE_ID=ws-6ee86ef2-5fd6-4600-bce0-a22a93ad23d2

ns="${NAMESPACE}"
echo "[Obs 40] Namespace=${ns}"

echo $WORKSPACE_ID

# Resolve WORKSPACE_ID (don't break if unset)
WS_ENV="${WORKSPACE_ID:-${WS:-}}"

# Show Grafana state
echo "# Grafana pod status"
kubectl -n "${ns}" get deploy grafana || true
kubectl -n "${ns}" get pods -l app=grafana -o wide || true
echo

echo "# Grafana admin credentials"
user="$(kubectl -n "${ns}" get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 --decode || true)"
pass="$(kubectl -n "${ns}" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode || true)"
echo "user: ${user:-admin}"
echo "pass: ${pass:-<secret>}"

# Port-forward helpers (kill existing PFs if any)
echo "# Port-forward local endpoints"
kill_port() { lsof -ti tcp:$1 | xargs -r kill -9 >/dev/null 2>&1 || true; }

echo
echo "kill existing port-forwards if any"
kill_port 3000; kill_port 9090; kill_port 8005

kubectl -n "${ns}" port-forward svc/grafana 3000:3000 >/tmp/grafana_pf.log 2>&1 &
echo "Grafana => http://127.0.0.1:3000  (logs: /tmp/grafana_pf.log)  [user=${user:-admin}]"

# OpenCost UI (try common service names)
if kubectl -n opencost get svc opencost >/dev/null 2>&1; then
  kubectl -n opencost port-forward svc/opencost 9090:9090 >/tmp/opencost_pf.log 2>&1 &
  echo "OpenCost UI => http://127.0.0.1:9090  (logs: /tmp/opencost_pf.log)"
elif kubectl -n opencost get svc opencost-ui >/dev/null 2>&1; then
  kubectl -n opencost port-forward svc/opencost-ui 9090:9090 >/tmp/opencost_pf.log 2>&1 &
  echo "OpenCost UI => http://127.0.0.1:9090  (logs: /tmp/opencost_pf.log)"
else
  echo "(OpenCost UI service not found in namespace 'opencost')"
fi

# AMP proxy (only if we have a workspace id)
if kubectl -n opencost get svc amp-sigv4-proxy >/dev/null 2>&1; then
  if [[ -n "${WORKSPACE_ID}" && "${WORKSPACE_ID}" != "None" ]]; then
    kubectl -n opencost port-forward svc/amp-sigv4-proxy 8005:8005 >/tmp/amp_pf.log 2>&1 &
    echo "AMP proxy => http://127.0.0.1:8005/workspaces/${WORKSPACE_ID}/api/v1/query  (logs: /tmp/amp_pf.log)"
    echo
    echo "# Quick test against AMP (metric names)"
  else
    echo "(WORKSPACE_ID not set; skipping AMP port-forward)"
    echo "Export it and re-run, e.g.:"
    echo "  export WORKSPACE_ID=\$(aws --profile \"$PROFILE\" --region \"$AWS_REGION\" amp list-workspaces \\"
    echo "     --query \"sort_by(workspaces[?status.statusCode==\\\`ACTIVE\\\`], &createdAt)[-1].workspaceId\" --output text)"
    echo "Or pick from:"
    aws --profile "${PROFILE}" --region "${AWS_REGION}" amp list-workspaces \
      --query "sort_by(workspaces, &createdAt)[].{ID:workspaceId,Alias:alias,Status:status.statusCode,Created:createdAt}" \
      --output table || true
  fi
else
  echo "(amp-sigv4-proxy service not found in 'opencost'; run your 06 opencost step)"
fi

