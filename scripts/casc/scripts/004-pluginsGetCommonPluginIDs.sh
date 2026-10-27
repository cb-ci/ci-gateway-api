#!/bin/bash

# Compute script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"


# Temporary file to store intermediate plugin lists
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Extract plugin IDs from each file and sort
i=0
for f in $(find $BASE_PATH  -iname plugins.yaml); do
  yq e '.plugins[].id' "$f" | sort > "$TMP_DIR/plugins_$i.txt"
  ((i++))
done

# Initialize result with first file
cp "$TMP_DIR/plugins_0.txt" "$TMP_DIR/common.txt"

# Intersect with remaining files
for j in $(seq 1 $((i - 1))); do
  comm -12 "$TMP_DIR/common.txt" "$TMP_DIR/plugins_$j.txt" > "$TMP_DIR/tmp.txt"
  mv "$TMP_DIR/tmp.txt" "$TMP_DIR/common.txt"
done

# Output result

#cat "$TMP_DIR/common.txt"
> plugins-common.yaml
echo "plugins:" > plugins-common.yaml
#cat "$TMP_DIR/common.txt" | sed -e "s/^/- id: /g" -e "s/\sversion/\s#version/g" >> plugins-common.yaml
cat "$TMP_DIR/common.txt" | sed -e "s/^/- id: /g" -e "s/\sversion.*$//g" > plugins-common-tmp.yaml
cat plugins-common-tmp.yaml |sort |uniq >> plugins-common.yaml
rm plugins-common-tmp.yaml
