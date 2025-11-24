\
#!/usr/bin/env bash
set -euo pipefail
source ./demo_00_env.sh

: "${PEAK_ZONES:=}"

# Build a JSON array from args (zone names are simple tokens)
json_array() {
  local first=1
  printf '['
  for it in "$@"; do
    [ -n "$it" ] || continue
    if [ $first -eq 0 ]; then printf ','; fi
    printf '"%s"' "$it"
    first=0
  done
  printf ']'
}

detect_zones() {
  local zones_str=""
  if [ -n "${PEAK_ZONES}" ]; then
    zones_str="${PEAK_ZONES//,/ }"
    printf "[zones] Using PEAK_ZONES from env: %s\n" "${zones_str}" >&2
  else
    zones_str="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | sort -u | awk 'NF' | tr '\n' ' ')"
    if [ -n "${zones_str// /}" ]; then
      printf "[zones] Derived from current cluster nodes: %s\n" "${zones_str}" >&2
    else
      if command -v aws >/dev/null 2>&1; then
        zones_str="$(aws ec2 describe-availability-zones --region "${AWS_REGION}" \
          --filters "Name=state,Values=available" \
          --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null | tr '\t' ' ')"
        if [ -n "${zones_str// /}" ] ; then
          printf "[zones] Discovered via AWS API: %s\n" "${zones_str}" >&2
        fi
      fi
      if [ -z "${zones_str// /}" ]; then
        zones_str="${AWS_REGION}a ${AWS_REGION}b ${AWS_REGION}c"
        printf "[zones] Fallback default: %s\n" "${zones_str}" >&2
      fi
    fi
  fi
  echo "${zones_str}"
}

ZONES_STR="$(detect_zones)"
ZONES_ARR=()
for z in ${ZONES_STR}; do ZONES_ARR+=("$z"); done
ZONES_JSON="$(json_array "${ZONES_ARR[@]}")"

echo "[config] Applying PEAK profile to ${NP_SPOT} (cost) and ${NP_OD} (SLO)"

# Disruption settings: Peak = WhenEmpty with consolidateAfter (required by validator).
kubectl patch nodepool "${NP_SPOT}" --type=merge -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty","consolidateAfter":"120s"}}}'
kubectl patch nodepool "${NP_OD}"   --type=merge -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty","consolidateAfter":"120s"}}}'

# Helper to write a JSON patch file for a given template path (either /spec/template/spec or /spec/template)
write_req_patch() {
  local path_prefix="$1" # /spec/template/spec  OR  /spec/template
  local np="$2"         # nodepool name
  local outfile="$3"
  {
    printf '[{"op":"add","path":"%s/requirements","value":[' "${path_prefix}"
    # First requirement: zone In [ZONES_JSON]
    printf '{"key":"topology.kubernetes.io/zone","operator":"In","values":%s}' "${ZONES_JSON}"
    printf ','
    # Second requirement: capacity-type (cost pool allows both; SLO pins to on-demand)
    if [ "$np" = "${NP_SPOT}" ]; then
      printf '{"key":"karpenter.sh/capacity-type","operator":"In","values":["spot","on-demand"]}'
    else
      printf '{"key":"karpenter.sh/capacity-type","operator":"In","values":["on-demand"]}'
    fi
    printf ']}]\n'
  } > "$outfile"
}

# Apply requirements patch with primary path, verify; if not visible there, retry fallback path.
apply_and_verify() {
  local np="$1"
  local primary="/spec/template/spec"
  local fallback="/spec/template"
  local tmp="/tmp/np_req_${np}.json"

  echo "[patch] Writing primary JSON Patch for $np at path ${primary}/requirements"
  write_req_patch "${primary}" "${np}" "${tmp}"
  kubectl patch nodepool "${np}" --type='json' --patch-file "${tmp}" || true

  # Verify primary path
  local got
  got="$(kubectl get nodepool "${np}" -o jsonpath='{range .spec.template.spec.requirements[*]}{.key}={.operator}:{range .values[*]}{.} {end}{"\n"}{end}' 2>/dev/null || true)"
  if [ -n "${got// /}" ]; then
    echo "[ok] Requirements present on ${np} under .spec.template.spec.requirements"
    echo "${got}"
    return 0
  fi

  echo "[info] Trying fallback path for $np: ${fallback}/requirements"
  write_req_patch "${fallback}" "${np}" "${tmp}"
  kubectl patch nodepool "${np}" --type='json' --patch-file "${tmp}"

  # Verify fallback path
  got="$(kubectl get nodepool "${np}" -o jsonpath='{range .spec.template.requirements[*]}{.key}={.operator}:{range .values[*]}{.} {end}{"\n"}{end}' 2>/dev/null || true)"
  if [ -n "${got// /}" ]; then
    echo "[ok] Requirements present on ${np} under .spec.template.requirements"
    echo "${got}"
    return 0
  fi

  echo "[err] Requirements not visible via jsonpath on ${np}. Dumping spec snippet:"
  kubectl get nodepool "${np}" -o yaml | sed -n '/^spec:/,/^status:/p' | sed -n '1,200p'
  return 1
}

apply_and_verify "${NP_SPOT}"
apply_and_verify "${NP_OD}"

echo "[ok] Peak profile applied."
