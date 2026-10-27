#! /bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

INPUT_DIR="${CASC_BUNDLES_PATH}/splitdir"

# Merge all sniplets back ino an new jenkins.yaml
yq ea '. as $d ireduce ({}; . *+ $d)' "$INPUT_DIR"/*.yaml > jenkins.rebuilt.yaml

# Desired root key order (spell exactly as in the YAML)
WANTED_ORDER=(jenkins beekeeper support globalCredentialsConfiguration appearance security unclassified tool)
SKELETON=$(mktemp)
for k in "${WANTED_ORDER[@]}"; do
  printf '%s: {}\n' "$k"
done > "$SKELETON"

yq ea '. as $d ireduce ({}; . *+ $d)' "$SKELETON" jenkins.rebuilt.yaml > jenkins.rebuilt.resorted.yaml



