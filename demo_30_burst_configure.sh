\
#!/usr/bin/env bash
# Demo 30: Burst generator (safe YAML, per-deployment temp files; fixed tolerations indentation)
set -euo pipefail
source ./demo_00_env.sh

COUNT="${COUNT:-12}"       # number of deployments to create
REPLICAS="${REPLICAS:-5}"  # replicas per deployment
ns="${NAMESPACE}"

echo "[Demo 30 burst] Using namespace: ${ns}  COUNT=${COUNT}  REPLICAS=${REPLICAS}"

# Ensure namespace + SA exist
kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}"
kubectl -n "${ns}" get sa scale-burst >/dev/null 2>&1 || kubectl -n "${ns}" create sa scale-burst

# Minimal RBAC (skip if already sufficient)
if ! kubectl auth can-i --as="system:serviceaccount:${ns}:scale-burst" --namespace "${ns}" '*' 'deployments.apps' >/dev/null 2>&1 \
   || ! kubectl auth can-i --as="system:serviceaccount:${ns}:scale-burst" --namespace "${ns}" '*' 'services' >/dev/null 2>&1; then
  echo "[rbac] Applying minimal Role/RoleBinding for scale-burst in ${ns}"
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-writer
  namespace: ${ns}
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","watch","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scale-writer-binding
  namespace: ${ns}
subjects:
- kind: ServiceAccount
  name: scale-burst
  namespace: ${ns}
roleRef:
  kind: Role
  name: scale-writer
  apiGroup: rbac.authorization.k8s.io
EOF
else
  echo "[rbac] Existing permissions for scale-burst look good; skipping Role/RoleBinding."
fi

# Create alternating spot/on-demand deployments directly
i=1
while [ "$i" -le "$COUNT" ]; do
  if [ $((i%2)) -eq 1 ]; then
    cap="spot"
    raw_tol="tolerations: []"
  else
    cap="on-demand"
    read -r -d '' raw_tol <<'TOL' || true
tolerations:
  - key: "critical"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
TOL
  fi

  # Indent the tolerations block by exactly 6 spaces so all lines align under 'spec:'
  tol_block="$(printf '%s\n' "${raw_tol}" | sed 's/^/      /')"

  name="burst-web-$i"
  tmp="$(mktemp -t burst-web.yaml.XXXXXX)"
  cat > "$tmp" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: burst-web
    group: scale-burst
    idx: "${i}"
    capacity: "${cap}"
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: burst-web
      group: scale-burst
      idx: "${i}"
  template:
    metadata:
      labels:
        app: burst-web
        group: scale-burst
        idx: "${i}"
        capacity: "${cap}"
    spec:
      nodeSelector:
        karpenter.sh/capacity-type: "${cap}"
${tol_block}
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web
        image: ghcr.io/nginxinc/nginx-unprivileged:stable-alpine
        imagePullPolicy: IfNotPresent
        ports:
          - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        securityContext:
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - "ALL"
        resources:
          requests:
            cpu: "200m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
EOF

  if ! kubectl -n "${ns}" apply -f "$tmp"; then
    echo "[error] Failed to apply ${name}. Dumping YAML:"
    sed -n '1,200p' "$tmp"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  i=$((i+1))
done

echo "[ok] Created ${COUNT} deployments. Next: ./demo_30_burst_observe.sh"
