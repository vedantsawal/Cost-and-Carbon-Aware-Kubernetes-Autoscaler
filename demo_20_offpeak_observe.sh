\
#!/usr/bin/env bash
set -euo pipefail
source ./demo_00_env.sh

ns="${NAMESPACE}"

echo "[Observe] Disruption settings"
for np in "${NP_SPOT}" "${NP_OD}"; do
  echo "== $np =="
  kubectl get nodepool "$np" -o jsonpath='consolidationPolicy={.spec.disruption.consolidationPolicy}  consolidateAfter={.spec.disruption.consolidateAfter}{"\n"}'
done

echo
echo "[Observe] Requirements (.spec.template.spec.requirements via go-template)"
for np in "${NP_SPOT}" "${NP_OD}"; do
  echo "== $np =="
  kubectl get nodepool "$np" -o go-template='{{range .spec.template.spec.requirements}}{{.key}}={{.operator}}: {{range .values}}{{.}} {{end}}{{"\n"}}{{end}}' || true
  echo
done

echo "[Observe] Raw YAML snippet around template:"
for np in "${NP_SPOT}" "${NP_OD}"; do
  echo "== $np =="
  kubectl get nodepool "$np" -o yaml | sed -n '/^spec:/,/^status:/p' | sed -n '1,200p'
  echo
done

echo "[Note] If values now render correctly above, the previous blank output was just a jsonpath formatting quirk."
