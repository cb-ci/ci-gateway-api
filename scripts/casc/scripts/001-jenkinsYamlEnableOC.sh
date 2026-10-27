#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"


TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

for jenkins_yaml in $(find $CASC_BUNDLES_PATH  -iname $JENKINS_YAML);do
    PARENT_DIR_NAME=$(basename "$(dirname "$jenkins_yaml")")

    if [[ $PARENT_DIR_NAME == "Operations-center" ]]; then
      echo "Parent directory matches 'Operations-center', skip patch"
    else
      echo "Patch $PARENT_DIR_NAME"
      OUTPUT_FILE=$TMP_DIR/"tmp-jenkins-patched.yaml"
      # Copy the original to modify
      cp -f $jenkins_yaml $OUTPUT_FILE
      yq -i '.jenkins.securityRealm = "operationsCenter"' $OUTPUT_FILE
      yq -i '(.jenkins.securityRealm) style="double"' $OUTPUT_FILE
      yq -i '.jenkins.authorizationStrategy = "cloudBeesRoleBasedAccessControl"'  $OUTPUT_FILE
      yq -i '(.jenkins.authorizationStrategy) style="double"' $OUTPUT_FILE
      yq -i '.jenkins.clouds += ["operationsCenterAgentProvisioningService"]'  $OUTPUT_FILE


      yq e --indent=2 --no-colors '.' "$OUTPUT_FILE" > tmp.yaml && mv tmp.yaml "$OUTPUT_FILE"
      cp -f $OUTPUT_FILE $jenkins_yaml
      echo "✅ Patch applied successfully to: $jenkins_yaml"
    fi
done
