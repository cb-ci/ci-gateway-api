#!/bin/bash

# Compute script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"



# put all plugins in one file

for i in $(find $BASE_PATH/  -iname plugins.yaml);do cat  $i >> plugins-all-tmp.yaml;done

#normalize the plugin list
cat plugins-all-tmp.yaml |sort |uniq >  plugins-all.yaml
sed -i s/plugins://g plugins-all.yaml
#sed -i '1i plugins:' plugins-all.yaml
rm plugins-all-tmp.yaml
cat plugins-all.yaml

