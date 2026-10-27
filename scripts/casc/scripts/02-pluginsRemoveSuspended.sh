#!/bin/bash

# Compute script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

# List of suspended plugin IDs for exact match
SUSPENDED_PLUGINS_EXACT=(
    "windows-slaves"
    "momentjs"
    "blueocean"
    "analysis-core"
    "handlebars"
    "cyberark-writer-plugin"
    "nexus-jenkins-plugin"
    "confluence-publisher"
    "greenballs"
    "scripttrigger"
    "build-flow-plugin"
    "handlebars"
)

# List of suspended plugin ID prefixes (regex)
SUSPENDED_PLUGINS_PREFIX=(
    "^blueocean-"
)

# --- Build yq query ---
conditions=()
for plugin_id in "${SUSPENDED_PLUGINS_EXACT[@]}"; do
    conditions+=(".id == \"$plugin_id\"")
done

for plugin_prefix in "${SUSPENDED_PLUGINS_PREFIX[@]}"; do
    conditions+=("(.id | test(\"$plugin_prefix\"))")
done

if [ ${#conditions[@]} -eq 0 ]; then
    echo "No plugins to remove."
    exit 0
fi

query_conditions=$(printf " or %s" "${conditions[@]}")
query_conditions=${query_conditions:4} # Remove leading " or "

yq_query=".plugins |= map(select(($query_conditions) | not))"
# --- End build yq query ---


for plugins_yaml in $(find "$CASC_BUNDLES_PATH" -iname "$PLUGINS_YAML");do
      echo "Update $plugins_yaml"
      yq -i "${yq_query}" "$plugins_yaml"
done
