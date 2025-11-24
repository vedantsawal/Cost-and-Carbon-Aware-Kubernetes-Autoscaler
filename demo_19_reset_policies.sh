#!/usr/bin/env bash
# demo_19_reset_policies.sh
# Purpose: Undo/neutralize the effects of demo_20_offpeak_configure.sh,
#          demo_21_peak_configure.sh, and demo_30_burst_configure.sh
#          while keeping base setup intact.
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

echo "[Reset 19] Cluster=${CLUSTER_NAME}  Region=${AWS_REGION}  Namespace=${NAMESPACE}"
echo "[Reset 19] NodePools: spot=${NP_SPOT}  on-demand=${NP_OD}"

echo
echo "[A] Remove burst workloads (group=scale-burst) …"
kubectl -n "${NAMESPACE}" delete deploy -l group=scale-burst --ignore-not-found
kubectl -n "${NAMESPACE}" delete svc -l group=scale-burst --ignore-not-found || true
kubectl -n "${NAMESPACE}" get pods -o wide || true

echo
echo "[B] Neutralize NodePool policies …"
read -r -d '' SPOT_JSON <<'JSON'
{
  "spec": {
    "disruption": {
      "consolidateAfter": "30s",
      "consolidationPolicy": "WhenEmpty",
      "budgets": [ { "nodes": "10%" } ]
    },
    "template": {
      "spec": {
        "expireAfter": "720h",
        "requirements": [
          { "key": "karpenter.k8s.aws/instance-category", "operator": "In", "values": ["c","m","r"] },
          { "key": "karpenter.sh/capacity-type",          "operator": "In", "values": ["spot"] }
        ]
      }
    }
  }
}
JSON

read -r -d '' OD_JSON <<'JSON'
{
  "spec": {
    "disruption": {
      "consolidateAfter": "30s",
      "consolidationPolicy": "WhenEmpty",
      "budgets": [ { "nodes": "10%" } ]
    },
    "template": {
      "spec": {
        "expireAfter": "720h",
        "requirements": [
          { "key": "karpenter.k8s.aws/instance-category", "operator": "In", "values": ["c","m","r"] },
          { "key": "karpenter.sh/capacity-type",          "operator": "In", "values": ["on-demand"] }
        ]
      }
    }
  }
}
JSON

echo "[B1] Patch ${NP_SPOT} …"
kubectl patch nodepool "${NP_SPOT}" --type merge -p "${SPOT_JSON}"
echo "[B2] Patch ${NP_OD} …"
kubectl patch nodepool "${NP_OD}" --type merge -p "${OD_JSON}"

echo
echo "[C] Verify NodePool specs (snippet) …"
echo "# ${NP_SPOT}"
kubectl get nodepool "${NP_SPOT}" -o json | jq '.spec.disruption, .spec.template.spec.requirements'
echo "# ${NP_OD}"
kubectl get nodepool "${NP_OD}" -o json | jq '.spec.disruption, .spec.template.spec.requirements'

echo
echo "[D] Live status …"
kubectl get nodepool -o wide
kubectl get nodeclaims.karpenter.sh -o wide || true
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type -o wide

echo
echo "[Reset 19] Done. Re-run:"
echo "  ./demo_20_offpeak_configure.sh"
echo "  ./demo_21_peak_configure.sh"
echo "  ./demo_30_burst_configure.sh"
