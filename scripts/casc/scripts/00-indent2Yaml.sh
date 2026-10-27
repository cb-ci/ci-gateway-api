#!/bin/bash

# When exporting a CasC bundle from CloudBees CI, the yaml indent doesnt have 2 indents
# This script fixes the indent

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

YAML_FILE="*.yaml"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

for yaml in $(find $CASC_BUNDLES_PATH  -iname $YAML_FILE);do
    OUTPUT_FILE=$TMP_DIR/"tmp-jenkins-patched.yaml"
    # Copy the original to modify
    cp -f $yaml $OUTPUT_FILE
    yq e --indent=2 --no-colors '.' "$OUTPUT_FILE" > tmp.yaml && mv tmp.yaml "$OUTPUT_FILE"
    cp -f $OUTPUT_FILE $yaml
    echo "✅ Patch applied successfully to: $yaml"
done
