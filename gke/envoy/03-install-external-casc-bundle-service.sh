#! /bin/bash

set -eo pipefail

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Load environment variables
source "${ROOT_DIR}/../.env"
export KUBECONFIG="${ROOT_DIR}/../kubeconfig"


cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cjoc-secrets
type: Opaque
stringData:
  githubUser: ${CASC_SCM_USERNAME}
  githubToken: ${CASC_SCM_PASSWORD}
  cjocLoginPassword: ${CJOC_ADMIN_PASSWORD}
EOF


# Deploy env vars used for interpolation in CasC bundle.
cat << EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cjoc-casc-envvars
data:
  ADMIN_ID: "${CJOC_ADMIN_USER}"
  ADMIN_NAME: "${CJOC_ADMIN_USER}"
  ADMIN_EMAIL: "${CJOC_ADMIN_EMAIL}"
  CJOC_VERSION: "latest"
  NAMESPACE: "${NAMESPACE}"
  GATEWAY_NAME: "${GATEWAY_NAME}"
  GATEWAY_NAMESPACE: "${NAMESPACE}"
  AGENT_VERSION: "latest"
  GATEWAY_DOMAIN: "${CJOC_HOST_NAME}"
  GATEWAY_PORT: "443"
  CASC_SCM_BRANCH: "${CASC_SCM_BRANCH}"
  CONTROLLER_STORAGE_CLASS: "${CLOUDBEES_STORAGE_CLASS}"  
EOF

# Deploy the CasC Controller Bundle Service.
# This approach is the recommended alternative to the SCM Retriever:
# - Operations Center exposes an internal HTTP service that serves CasC bundles
#   to managed controllers on demand, removing per-controller retriever sidecars.
# - CasCBundleService.Enabled=true  → deploy the bundle-service sidecar in the OC pod.
# - CasCBundleService.createConfig=true → Helm auto-creates the
#   'casc-bundle-service-config' Secret in the OC namespace. Set to false if
#   you prefer to manage that Secret externally (it must exist before OC starts).
# - The OC CasC bundle is still fetched via the Retriever (see script 1); the
#   Bundle Service then distributes controller-level bundles to managed controllers.
# Reference: https://docs.cloudbees.com/docs/cloudbees-ci/latest/casc-controller/set-up-managed-controller-with-service
echo "Deploying CloudBees CI with CasC Controller Bundle Service via Helm..."
# helm upgrade --install cloudbees-core-envoy cloudbees/cloudbees-core \
#   --namespace "${NAMESPACE}" \
#   --set Gateway.Enabled=true \
#   --set Gateway.Name="${GATEWAY_NAME}" \
#   --set Gateway.SectionName=https \
#   --set Gateway.Namespace="${NAMESPACE}" \
#   --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
#   --set OperationsCenter.Protocol=https \
#   --set Agents.SeparateNamespace.Enabled=false \
#   --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
#   --set Common.image.tag='latest' \
#   --set OperationsCenter.CasC.Enabled=true \
#   --set OperationsCenter.CasC.Retriever.Enabled=true \
#   --set OperationsCenter.CasC.Retriever.scmRepo="${CASC_SCM_REPO}" \
#   --set OperationsCenter.CasC.Retriever.scmBundlePath="${CASC_SCM_BUNDLE_PATH}" \
#   --set OperationsCenter.CasC.Retriever.scmBranch="${CASC_SCM_BRANCH}" \
#   --set OperationsCenter.CasC.Retriever.scmPollingInterval="PT1M" \
#   --set OperationsCenter.CasC.Retriever.secrets.scmUsername="githubUser" \
#   --set OperationsCenter.CasC.Retriever.secrets.scmPassword="githubToken" \
#   --set OperationsCenter.CasC.Retriever.secrets.secretName="cjoc-secrets" \
#   --set OperationsCenter.ContainerEnvFrom[0].configMapRef.name="cjoc-casc-envvars" \
#   --set OperationsCenter.ExtraVolumes[0].name="cjoc-secrets" \
#   --set OperationsCenter.ExtraVolumes[0].secret.secretName="cjoc-secrets" \
#   --set OperationsCenter.ExtraVolumeMounts[0].name="cjoc-secrets" \
#   --set OperationsCenter.ExtraVolumeMounts[0].mountPath="/var/run/secrets/cjoc" \
#   --set OperationsCenter.ExtraVolumeMounts[0].readOnly=true \
#   --set CascBundleService.enabled=true \
#   --set CassBundleService.createConfig=true \
#   --debug

cat <<EOF | kubectl replace secret generic casc-bundle-service-config  -n ${NAMESPACE} -f - 
apiVersion: v1
kind: Secret
metadata:
  name: casc-bundle-service-config
  labels:
    app: casc-bundle-service
type: Opaque
stringData:
  service-configuration.yaml: |
    connectors:
    - id: id1
      url: ${CASC_SCM_REPO}
      branch: ${CASC_SCM_BRANCH}
      path: ${CASC_SCM_BUNDLE_PATH}
      type: scm
      credential:
        user: ${CASC_SCM_USERNAME}
        password: ${CASC_SCM_PASSWORD}
        type: userPassword
EOF


