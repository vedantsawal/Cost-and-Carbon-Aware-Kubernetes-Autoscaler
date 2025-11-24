\
#!/usr/bin/env bash
# Demo 30 Observe (v2): clean output + Pending diagnostics (no generator job)
set -euo pipefail
source ./demo_00_env.sh

ns="${NAMESPACE}"

echo "# Summary of created deployments (capacity alternates spot/on-demand)"
kubectl -n "${ns}" get deploy -l group=scale-burst \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,CAPACITY:.metadata.labels.capacity --no-headers || true
echo

echo "# Pods (snapshot)"
kubectl -n "${ns}" get pods -l group=scale-burst -o wide || true
echo

echo "# Scheduling diagnostics (why Pending?)"
# Show PodScheduled condition reason/message per pod (compact)
kubectl -n "${ns}" get pods -l group=scale-burst -o json \
  | jq -r '.items[] | [.metadata.name,
                       (.status.conditions[]? | select(.type=="PodScheduled") | .status // ""),
                       (.status.conditions[]? | select(.type=="PodScheduled") | .reason // ""),
                       (.status.conditions[]? | select(.type=="PodScheduled") | .message // "")] | @tsv' \
  2>/dev/null \
  | awk -F'\t' 'BEGIN{printf("%-36s  %-5s  %-28s  %s\n","POD","OK?","REASON","MESSAGE");
                       print "------------------------------------  -----  ----------------------------  ---------------------------------------------"} 
                {printf("%-36s  %-5s  %-28s  %s\n",$1,$2,$3,$4)}' || echo "(jq not available; skipping condition table)"
echo

echo "# Recent events (namespace ${ns})"
kubectl -n "${ns}" get events --sort-by=.lastTimestamp | tail -n 30 || true
echo

echo "# NodePools quick view"
kubectl get nodepool || true
echo

echo "# NodePool requirements (go-template)"
for np in $(kubectl get nodepool -o name 2>/dev/null | cut -d/ -f2); do
  echo "== ${np} =="
  kubectl get nodepool "${np}" -o go-template='{{range .spec.template.spec.requirements}}{{.key}}={{.operator}}: {{range .values}}{{.}} {{end}}{{"\n"}}{{end}}' || true
done
echo

echo "# Do we have a NodeClass named 'default-class'? (common in this demo)"
kubectl get ec2nodeclass default-class 2>/dev/null || echo "(ec2nodeclass/default-class not found)"
kubectl get nodeclass     default-class 2>/dev/null || true
echo

echo "# Karpenter controller status (if installed in 'karpenter' ns)"
kubectl -n karpenter get deploy,po 2>/dev/null || echo "(no karpenter namespace or controller not found)"
echo
echo "# Hint: If pods stay Pending and no new nodes appear, check controller logs:"
echo "  kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter -c controller --tail=200"
echo "  # Look for reasons like 'insufficient capacity', 'no matching NodeClass', or IAM/EC2 errors."
