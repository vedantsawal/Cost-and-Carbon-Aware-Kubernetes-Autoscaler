#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_common.sh"

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Install Kyverno"
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 10m

# Ensure controllers/webhook are ready before applying policies
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=5m
kubectl -n kyverno rollout status deploy/kyverno-background-controller --timeout=5m
kubectl -n kyverno rollout status deploy/kyverno-reports-controller --timeout=5m
kubectl -n kyverno rollout status deploy/kyverno-cleanup-controller --timeout=5m
until kubectl -n kyverno get endpoints kyverno-svc -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; do
  echo "waiting for kyverno-svc endpoints…"; sleep 5
done

log "Install sample kyverno-policies baseline"
helm upgrade --install kyverno-policies kyverno/kyverno-policies -n kyverno --wait --timeout 10m

log "Apply guard policy: require-requests-limits"
kubectl apply -f - <<'POL1'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: require-requests-limits }
spec:
  validationFailureAction: enforce
  background: true
  rules:
  - name: containers-require-limits
    match: { resources: { kinds: ["Pod"] } }
    validate:
      message: "All containers must have cpu/memory requests & limits"
      pattern:
        spec:
          containers:
          - resources:
              requests: { cpu: "?*", memory: "?*" }
              limits:   { cpu: "?*", memory: "?*" }
POL1

log "Apply FIXED guard policy: critical-no-spot-without-pdb"
# Replace any previous version to avoid webhook errors
kubectl delete cpol critical-no-spot-without-pdb >/dev/null 2>&1 || true
kubectl apply -f - <<'POL2'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: critical-no-spot-without-pdb
spec:
  validationFailureAction: enforce
  background: true
  rules:
    - name: deny-spot-for-critical
      match:
        any:
          - resources:
              kinds: ["Pod"]
              selector:
                matchLabels:
                  critical: "true"
      exclude:
        any:
          - resources:
              namespaces: ["karpenter","kyverno","kube-system"]
      validate:
        message: "Critical pods must avoid Spot capacity."
        deny:
          conditions:
            - key: "{{ length(request.object.spec.tolerations[?key=='karpenter.sh/capacity-type' && value=='spot']) }}"
              operator: GreaterThan
              value: 0
POL2

kubectl get clusterpolicy
log "Stage 04 OK (policies applied)."
