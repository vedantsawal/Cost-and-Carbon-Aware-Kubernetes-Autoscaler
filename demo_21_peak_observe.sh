\
#!/usr/bin/env bash
set -euo pipefail
source ./demo_00_env.sh

echo "# ${NP_SPOT} (cost pool) consolidation + consolidateAfter"
kubectl get nodepool "${NP_SPOT}" -o go-template='{{.spec.disruption.consolidationPolicy}} {{.spec.disruption.consolidateAfter}}{{"\n"}}'
echo "# ${NP_SPOT} requirements"
kubectl get nodepool "${NP_SPOT}" -o go-template='{{range .spec.template.spec.requirements}}{{.key}}={{.operator}}: {{range .values}}{{.}} {{end}}{{"\n"}}{{end}}'
echo

echo "# ${NP_OD} (SLO pool) consolidation + consolidateAfter"
kubectl get nodepool "${NP_OD}" -o go-template='{{.spec.disruption.consolidationPolicy}} {{.spec.disruption.consolidateAfter}}{{"\n"}}'
echo "# ${NP_OD} requirements"
kubectl get nodepool "${NP_OD}" -o go-template='{{range .spec.template.spec.requirements}}{{.key}}={{.operator}}: {{range .values}}{{.}} {{end}}{{"\n"}}{{end}}'
echo

echo "# Expect zones=[${PEAK_ZONES}] | ${NP_SPOT}: capacity-type=spot on-demand | ${NP_OD}: on-demand only"
