#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

# Defaults only if truly unset (not if set to empty)
: "${AWS_PROFILE:=default}"
: "${AWS_REGION:=us-east-2}"
: "${CLUSTER_NAME:=demo}"

log()  { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
req()  { for c in "$@"; do command -v "$c" >/dev/null || { err "Missing $c"; exit 1; }; done; }

# Hard fail if required vars are empty strings
require_var() { eval "v=\${$1:-}"; [[ -n "$v" ]] || { err "Required var $1 is empty. Set it in .env or env."; exit 1; }; }
require_var AWS_REGION
require_var CLUSTER_NAME

export AWS_PROFILE AWS_REGION CLUSTER_NAME

req aws eksctl kubectl helm jq

log "Using → CLUSTER_NAME=${CLUSTER_NAME}  AWS_REGION=${AWS_REGION}  AWS_PROFILE=${AWS_PROFILE}"
