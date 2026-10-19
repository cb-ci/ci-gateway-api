#!/usr/bin/env bash

set -euo pipefail

source .env

envsubst < eksctl-config.yaml.tpl > eksctl-config.yaml

echo "Deleting EKS cluster ${CLUSTER_NAME} in region ${AWS_DEFAULT_REGION}..."
eksctl delete cluster -f eksctl-config.yaml --wait --force --disable-nodegroup-eviction

echo "Cluster cleanup complete."
