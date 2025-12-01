#!/usr/bin/env bash
# demo_40_watch_configure.sh
# Deploy Grafana in your workload namespace and wire a Prometheus datasource to AMP
# via the amp-sigv4-proxy running in the 'opencost' namespace.

set -euo pipefail
source ./demo_00_env.sh

ns="${NAMESPACE:-nov-22}"

echo "[Obs 40] Using namespace=${ns}"

# Ensure namespace exists
kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}"

# Validate the proxy service exists
if ! kubectl -n opencost get svc amp-sigv4-proxy >/dev/null 2>&1; then
  echo "[error] amp-sigv4-proxy service not found in 'opencost' namespace."
  echo "        Install/verify your AMP SigV4 proxy from the 06-opencost step first."
  exit 1
fi

# Try to auto-detect AMP WORKSPACE_ID from ADOT config (fallback to env)
WORKSPACE_ID="${WORKSPACE_ID:-}"
if [[ -z "${WORKSPACE_ID}" || "${WORKSPACE_ID}" == "None" ]]; then
  if kubectl -n opencost get cm adot-config >/dev/null 2>&1; then
    WORKSPACE_ID="$(kubectl -n opencost get cm adot-config -o jsonpath='{.data.collector\.yaml}' \
      | grep -Eo 'workspaces/[A-Za-z0-9-]+' | head -n1 | cut -d/ -f2 || true)"
  fi
fi
: "${WORKSPACE_ID:?WORKSPACE_ID not found. Export WORKSPACE_ID or ensure opencost/adot-config exists.}"

echo "[Obs 40] AMP_WORKSPACE=${WORKSPACE_ID}"

# Grafana admin secret (create once)
if ! kubectl -n "${ns}" get secret grafana-admin >/dev/null 2>&1; then
  if command -v openssl >/dev/null 2>&1; then
    pw="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)"
  else
    pw="admin"
  fi
  kubectl -n "${ns}" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${pw}"
  echo "[grafana] Created admin secret (user=admin, auto-generated password)."
else
  echo "[grafana] Admin secret already present; leaving as-is."
fi

# Datasource provisioning (points Grafana → AMP through the cluster-local proxy)
cat > /tmp/grafana-datasource.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: ${ns}
  labels:
    grafana_datasource: "1"
data:
  amp-prom.yaml: |
    apiVersion: 1
    datasources:
    - name: AMP
      type: prometheus
      access: proxy
      isDefault: true
      url: http://amp-sigv4-proxy.opencost.svc:8005/workspaces/${WORKSPACE_ID}
      jsonData:
        timeInterval: 30s
        httpMethod: POST
EOF
kubectl apply -f /tmp/grafana-datasource.yaml

# Minimal Grafana deployment + service
cat > /tmp/grafana.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  labels: { app: grafana }
spec:
  replicas: 1
  selector:
    matchLabels: { app: grafana }
  template:
    metadata:
      labels: { app: grafana }
    spec:
      securityContext:
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: grafana
        image: grafana/grafana:10.4.2
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_USER
          valueFrom:
            secretKeyRef: { name: grafana-admin, key: admin-user }
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef: { name: grafana-admin, key: admin-password }
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "false"
        - name: GF_PATHS_PROVISIONING
          value: /etc/grafana/provisioning
        readinessProbe:
          httpGet: { path: /login, port: 3000 }
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet: { path: /api/health, port: 3000 }
          initialDelaySeconds: 10
          periodSeconds: 10
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasources
          items:
          - key: amp-prom.yaml
            path: amp-prom.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  labels: { app: grafana }
spec:
  selector: { app: grafana }
  ports:
  - port: 3000
    targetPort: 3000
    name: http
EOF

kubectl -n "${ns}" apply -f /tmp/grafana.yaml

echo "[Obs 40] Grafana applied. Next: ./demo_40_watch_observe.sh"
