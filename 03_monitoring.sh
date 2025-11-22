#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/00_common.sh"

log "Helm repos (idempotent)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Install kube-prometheus-stack"
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=2d \
  --wait --timeout 15m

log "Install Prometheus Adapter"
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring --set rules.default=true \
  --wait --timeout 10m

# Basic health
kubectl -n monitoring get pods
log "Grafana: open http://localhost:3000  (user: admin, pass: admin)"
log "Stage 03 OK"
