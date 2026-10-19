#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03-installClusterAutoscaler.sh — Install Kubernetes Cluster Autoscaler.
#
# WHY THIS EXISTS
#   eksctl-config.yaml already provisions the IRSA ServiceAccount
#   (kube-system/cluster-autoscaler, wellKnownPolicies autoScaler), and eksctl
#   auto-tags each managed node group's ASG for auto-discovery
#   (k8s.io/cluster-autoscaler/<cluster>=owned,
#   k8s.io/cluster-autoscaler/enabled=true) whenever minSize != maxSize —
#   true for both the `controllers` and `agents` pools. Nothing installs the
#   autoscaler pod itself though, so node groups never move off
#   desiredCapacity on their own; that gap is what the manual
#   01-scaleUpNodePools.sh / 01-scaleDonwNodePools.sh scripts work around.
#
# ORDER
#   Run AFTER 01-createCluster.sh. Independent of 03-installAwsLbController.sh
#   / 04-installEnvoy.sh.
#
# Usage: ./03-installClusterAutoscaler.sh
# -----------------------------------------------------------------------------
set -euo pipefail
source ./.env

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CA_CHART_VERSION="${CA_CHART_VERSION:-9.46.6}"

for bin in aws kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool '$bin' not found on PATH"
done

# -----------------------------------------------------------------------------
# 1. Sanity: the IRSA ServiceAccount must already exist (created by eksctl)
# -----------------------------------------------------------------------------
log "Verifying IRSA ServiceAccount kube-system/cluster-autoscaler..."
kubectl get sa cluster-autoscaler -n kube-system >/dev/null 2>&1 \
  || die "ServiceAccount missing — re-run eksctl with eksctl-config.yaml (iam.serviceAccounts)"

SA_ROLE=$(kubectl get sa cluster-autoscaler -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
[[ -n "$SA_ROLE" ]] || die "ServiceAccount has no eks.amazonaws.com/role-arn annotation — IRSA not wired up"
ok "IRSA role: ${SA_ROLE}"

# -----------------------------------------------------------------------------
# 2. Match the autoscaler image tag to the cluster's k8s minor version —
#    cluster-autoscaler releases track Kubernetes minor versions 1:1, and a
#    mismatched image is a common source of silent scaling failures.
# -----------------------------------------------------------------------------
K8S_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.version' --output text)
CA_IMAGE_TAG="${CA_IMAGE_TAG:-v${K8S_VERSION}.0}"
ok "Cluster k8s version: ${K8S_VERSION} -> cluster-autoscaler image tag ${CA_IMAGE_TAG}"
warn "If ${CA_IMAGE_TAG} doesn't exist on registry.k8s.io/autoscaling/cluster-autoscaler, override with CA_IMAGE_TAG=<tag>"

# -----------------------------------------------------------------------------
# 3. Sanity: ASG auto-discovery tags (eksctl sets these automatically when a
#    managed node group has minSize != maxSize — true for both pools here)
# -----------------------------------------------------------------------------
log "Checking node group ASGs are tagged for auto-discovery..."
TAGGED=$(aws autoscaling describe-tags --region "$AWS_REGION" \
  --filters "Name=key,Values=k8s.io/cluster-autoscaler/${CLUSTER_NAME}" "Name=value,Values=owned" \
  --query 'length(Tags)' --output text)
if [[ "$TAGGED" == "0" ]]; then
  warn "No ASGs tagged k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned — autoscaler will find nothing to scale."
else
  ok "${TAGGED} ASG(s) tagged for auto-discovery."
fi

# -----------------------------------------------------------------------------
# 4. Install the autoscaler
# -----------------------------------------------------------------------------
log "Installing cluster-autoscaler ${CA_CHART_VERSION}..."
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update autoscaler

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version "$CA_CHART_VERSION" \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$AWS_REGION" \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set image.tag="$CA_IMAGE_TAG"

log "Waiting for autoscaler rollout..."
# The chart's fullname isn't the release name — its internal app name is
# "aws-cluster-autoscaler" and Helm's fullname template appends that to the
# release name (cluster-autoscaler-aws-cluster-autoscaler), so discover the
# actual deployment by label instead of hardcoding a name that can drift
# across chart versions.
CA_DEPLOY=$(kubectl get deploy -n kube-system \
  -l app.kubernetes.io/instance=cluster-autoscaler -o jsonpath='{.items[0].metadata.name}')
[[ -n "$CA_DEPLOY" ]] || die "no deployment found with label app.kubernetes.io/instance=cluster-autoscaler"
kubectl rollout status "deployment/${CA_DEPLOY}" -n kube-system --timeout=180s

# -----------------------------------------------------------------------------
# 5. Supplemental RBAC for resource.k8s.io (Dynamic Resource Allocation)
#    Newer cluster-autoscaler builds unconditionally watch DRA objects
#    (ResourceSlice, DeviceClass, ResourceClaim, ResourceClaimTemplate, ... —
#    used only if workloads actually request DRA resources), but chart
#    9.46.6's bundled ClusterRole predates that and doesn't grant any of it.
#    Forcing CA_IMAGE_TAG ahead of the chart's tested app version re-creates
#    this gap on every install. Rather than allowlist resource.k8s.io kinds
#    one watch-error at a time, grant the whole API group read-only —
#    harmless no-op if a future chart version already grants it.
# -----------------------------------------------------------------------------
log "Granting supplemental resource.k8s.io (DRA) read permissions..."
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler-dra
rules:
  - apiGroups: ["resource.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler-dra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-autoscaler-dra
subjects:
  - kind: ServiceAccount
    name: cluster-autoscaler
    namespace: kube-system
EOF

ok "Cluster Autoscaler ready. The controllers (1-2) and agents (1-2) node groups now scale on pod pressure."
log "Watch it working: kubectl logs -n kube-system deploy/${CA_DEPLOY} -f"
