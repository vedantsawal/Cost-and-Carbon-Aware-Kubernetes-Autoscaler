#!/usr/bin/env bash
# demo_50_cleanup_configure.sh — Tear down demo workloads + Karpenter demo resources
set -Eeuo pipefail
set +H

# Load env the same way the other demo scripts do
source "$(dirname "$0")/demo_00_env.sh"

NS="${NS:-${NAMESPACE:-nov-22}}"

log(){ echo -e "[Cleanup 50] $*"; }

log "Cluster=${CLUSTER_NAME:-?}  Region=${AWS_REGION:-?}  Namespace=${NS}"

# 0) Kill local PFs we might have spawned
log "Killing old port-forwards on 3000, 8005, 9090…"
for p in 3000 8005 9090; do lsof -ti tcp:$p | xargs -r kill -9 || true; done

# 1) Remove demo workloads/namespaces
log "Deleting demo namespace ${NS}…"
kubectl delete ns "${NS}" --ignore-not-found --wait=true

log "Deleting quick-verify namespace (if present)…"
kubectl delete ns karpenter-verify --ignore-not-found --wait=true

# 2) Remove NodePools first to stop new provisioning
log "Deleting NodePools spot-preferred, on-demand-slo…"
kubectl delete nodepool spot-preferred on-demand-slo --ignore-not-found || true

# 3) Delete remaining NodeClaims (with finalizer rescue)
log "Deleting NodeClaims (no-wait) and scrubbing finalizers if any remain…"
kubectl get nodeclaim -A -o name | xargs -r kubectl delete --wait=false || true
# Finalizer rescue (harmless if none)
kubectl get nodeclaim -A -o name | xargs -r -I{} kubectl patch {} \
  -p '{"metadata":{"finalizers":[]}}' --type=merge || true

# 4) Delete Karpenter-owned Nodes so next run starts clean
log "Deleting Karpenter-owned Nodes…"
kubectl get nodes -l 'karpenter.sh/nodepool' -o name | xargs -r kubectl delete || true

# 5) Optional: remove the demo NodeClass (keeps Karpenter installed, but wipes demo infra)
if [[ "${WIPE_NODECLASS:-false}" == "true" ]]; then
  log "WIPE_NODECLASS=true → Deleting EC2NodeClass default-ec2…"
  kubectl delete ec2nodeclass default-ec2 --ignore-not-found || true
fi

# 6) Confirm empty state
log "Post-cleanup snapshot:"
kubectl get nodepool || true
kubectl get nodeclaim -A || true
kubectl get nodes -l 'karpenter.sh/nodepool' -o wide || true

log "Done. You can now restart with: 
  ./demo_01_nodepool_configure.sh
  ./demo_10_setup_configure.sh
  ./demo_18_preroll_check.sh
  ./demo_20_offpeak_configure.sh
  ./demo_21_peak_configure.sh
  ./demo_30_burst_configure.sh
  ./demo_40_watch_configure.sh
  ./demo_40_watch_observe.sh"
