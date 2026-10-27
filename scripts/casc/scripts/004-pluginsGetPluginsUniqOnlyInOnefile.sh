#!/bin/bash

# Compute script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"
PLUGINS_COMMON=${1:-"plugins-common.yaml"}

for pluginsYaml in $(find $BASE_PATH  -iname plugins.yaml); do
    # Temporary file to store intermediate plugin lists
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT

    PLUGINS_CONTROLER=$pluginsYaml
    TMP_ONLY_CONTROLLER_PLUGINS=$TMP_DIR/plugins.yaml
    > $TMP_DIR/plugins.yaml
    echo "############################################"
    echo "Plugins only available in Controller $PLUGINS_CONTROLER"
    echo "plugins:" > $TMP_ONLY_CONTROLLER_PLUGINS
    comm -13 <(yq e '.plugins[].id' $PLUGINS_COMMON |sort) <(yq e '.plugins[].id' $PLUGINS_CONTROLER |sort) |tee -a $TMP_ONLY_CONTROLLER_PLUGINS
    sed -i '2,$s/^/- id: /g' "$TMP_ONLY_CONTROLLER_PLUGINS"
    cat $TMP_ONLY_CONTROLLER_PLUGINS > $PLUGINS_CONTROLER


    echo "############################################"
    echo "Plugins in Controller $PLUGINS_COMMON"
    comm -2 <(yq e '.plugins[].id' $PLUGINS_COMMON  |sort) <(yq e '.plugins[].id' $PLUGINS_CONTROLER |sort)

    echo "############################################"
    echo "Nr. of Plugins only available in Controller $PLUGINS_CONTROLER"
    comm -13 <(yq e '.plugins[].id' $PLUGINS_COMMON  |sort) <(yq e '.plugins[].id' $PLUGINS_CONTROLER |sort)  | wc -l

    echo "Nr. of Plugins in $PLUGINS_COMMON"
    comm -2 <(yq e '.plugins[].id' $PLUGINS_COMMON  |sort) <(yq e '.plugins[].id' $PLUGINS_CONTROLER |sort)  | wc -l

done