#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

# Derive full paths based on environment variables
JENKINS_YAML="${CASC_BUNDLES_PATH}/${JENKINS_YAML}"
OUTDIR="${CASC_BUNDLES_PATH}/splitdir"
mkdir -p "$OUTDIR"

# List root (top-level) keys
yq e -r 'keys | .[]' "$JENKINS_YAML" | while IFS= read -r ROOT; do
  export ROOT
  # List 2nd-level keys; if .[ROOT] isn't a map, `// {}` yields empty map => no keys
  yq e -r '.[env(ROOT)] // {} | keys | .[]' "$JENKINS_YAML" | while IFS= read -r KEY; do
    export KEY
    # Safe filenames; keep dots/dashes/underscores
    safe_root="$(printf '%s' "$ROOT" | sed 's#[^A-Za-z0-9._-]#_#g')"
    safe_key="$(printf  '%s' "$KEY"  | sed 's#[^A-Za-z0-9._-]#_#g')"

    # Emit a file shaped as:
    # <ROOT>:
    #   <KEY>: <value>
    yq e -o=yaml -I 2 '
      . as $d
      | { (env(ROOT)): { (env(KEY)): $d[env(ROOT)][env(KEY)] } }
    ' "$JENKINS_YAML" > "$OUTDIR/${safe_root}.${safe_key}.yaml"
  done
done




