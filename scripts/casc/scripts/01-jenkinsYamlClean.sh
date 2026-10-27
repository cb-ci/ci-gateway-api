#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

# Transform file for cleaning script
TRANSFORM_FILE="../transform.yaml"

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

for jenkins_yaml in $(find $CASC_BUNDLES_PATH  -iname $JENKINS_YAML);do
    OUTPUT_FILE=$TMP_DIR/"tmp-jenkins-patched.yaml"
    # Copy the original to modify
    cp -f $jenkins_yaml $OUTPUT_FILE
    #cat $OUTPUT_FILE
    echo "🔧 Applying patch from $TRANSFORM_FILE to $OUTPUT_FILE"

    # Loop through each remove operation
    INDEX=0
    yq e '.[] | select(.op == "remove") | .path' "$TRANSFORM_FILE" | while read -r path; do
      CLEAN_PATH="${path#/}"  # Strip leading slash
      echo $CLEAN_PATH
      echo "[$((++INDEX))] ❌ Removing: .$CLEAN_PATH"
      yq -i "del(.${CLEAN_PATH})" "$OUTPUT_FILE"
    done
    yq e --indent=2 --no-colors '.' "$OUTPUT_FILE" > tmp.yaml && mv tmp.yaml "$OUTPUT_FILE"
    cp -f $OUTPUT_FILE $jenkins_yaml
    echo "✅ Patch applied successfully to: $jenkins_yaml"
done
