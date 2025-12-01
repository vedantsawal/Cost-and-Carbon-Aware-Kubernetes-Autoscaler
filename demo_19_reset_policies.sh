#!/usr/bin/env bash
# demo_19_reset_policies.sh — normalize NodePool disruption + (optionally) clean stale port-forwards
set -Eeuo pipefail

# ==== Demo env (prints CLUSTER/REGION/NS banner like others) ====
source "$(dirname "$0")/demo_00_env.sh"

: "${RESET_KILL_PF:=true}"          # set to "false" to skip PF cleanup
: "${PF_PORTS:="3000 8005 9090"}"   # override if you use different local ports

NP_SPOT="spot-preferred"
NP_OD="on-demand-slo"
echo "[Reset 19] Cluster=${CLUSTER_NAME}  Region=${AWS_REGION}"
echo "[Reset 19] Target NodePools: ${NP_SPOT}, ${NP_OD}"

# ---- Helper: patch NodePool safely ----
patch_np() {
  local np="$1"
  if kubectl get nodepool "${np}" >/dev/null 2>&1; then
    # Ensure consolidationPolicy=WhenEmpty and consolidateAfter is present (required by validation)
    echo "[Reset 19] ${np}: setting consolidationPolicy=WhenEmpty, consolidateAfter=30s"
    kubectl patch nodepool "${np}" --type=merge -p '{
      "spec": {
        "disruption": {
          "consolidationPolicy": "WhenEmpty",
          "consolidateAfter": "30s"
        }
      }
    }' >/dev/null
  else
    echo "[Reset 19] ${np}: not found, skipping"
  fi
}

patch_np "${NP_SPOT}"
patch_np "${NP_OD}"

# ---- Optional: clean only kubectl port-forwards on common demo ports ----
if [[ "${RESET_KILL_PF}" == "true" ]]; then
  echo "[Reset 19] Cleaning stale kubectl port-forwards on ports: ${PF_PORTS}"
  for p in ${PF_PORTS}; do
    # Kill only kubectl PFs that expose :PORT on localhost
    # (safe against other processes that may also listen on these ports)
    pkill -f "kubectl .*port-forward .*:${p}(\\b|$)" 2>/dev/null || true
  done

  # Show any survivors (useful for debugging)
  for p in ${PF_PORTS}; do
    if lsof -i :"${p}" >/dev/null 2>&1; then
      echo "[Reset 19] ⚠️ Port ${p} still in use:"
      lsof -i :"${p}" || true
    else
      echo "[Reset 19] ✅ Port ${p} is free"
    fi
  done
else
  echo "[Reset 19] Skipping port-forward cleanup (RESET_KILL_PF=false)"
fi

# ---- Verify final state ----
echo "[Verify] NodePool readiness (last condition):"
kubectl get nodepool -o jsonpath='{range .items[*]}{.metadata.name} -> {.status.conditions[-1].type} {.status.conditions[-1].status}{"\n"}{end}' || true
echo "[Verify] Disruption policies:"
kubectl get nodepool "${NP_SPOT}" "${NP_OD}" -o jsonpath='{range .items[*]}{.metadata.name} -> {.spec.disruption.consolidationPolicy} / {.spec.disruption.consolidateAfter}{"\n"}{end}' 2>/dev/null || true
