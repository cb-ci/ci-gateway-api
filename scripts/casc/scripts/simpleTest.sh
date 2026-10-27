#! /bin/bash

CLEAN_PATH="jenkins.agentProtocols"
FILE="../casc/CCOE-containers-core-casc-export-jenkins/before-transform-jenkins.yaml"

yq -i "del(.${CLEAN_PATH})" "$FILE"