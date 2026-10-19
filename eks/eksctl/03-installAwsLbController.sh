#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03-installAwsLbController.sh — Install the AWS Load Balancer Controller.
#
# WHY THIS EXISTS
#   eksctl-config.yaml already provisions the IRSA ServiceAccount
#   (kube-system/aws-load-balancer-controller, wellKnownPolicies
#   awsLoadBalancerController), but nothing ever installed the controller
#   itself. Without it, no Ingress is ever reconciled into an ALB and the
#   Ingress created by 04-installEnvoy.sh sits with an empty ADDRESS forever.
#
# ORDER
#   Run AFTER 01-createCluster.sh and BEFORE 04-installEnvoy.sh.
#
# Usage: ./03-installAwsLbController.sh
# -----------------------------------------------------------------------------
set -euo pipefail
source ./.env

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
LBC_CHART_VERSION="${LBC_CHART_VERSION:-1.14.0}"

for bin in aws kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool '$bin' not found on PATH"
done

# -----------------------------------------------------------------------------
# 1. Sanity: the IRSA ServiceAccount must already exist (created by eksctl)
# -----------------------------------------------------------------------------
log "Verifying IRSA ServiceAccount kube-system/aws-load-balancer-controller..."
kubectl get sa aws-load-balancer-controller -n kube-system >/dev/null 2>&1 \
  || die "ServiceAccount missing — re-run eksctl with eksctl-config.yaml (iam.serviceAccounts)"

SA_ROLE=$(kubectl get sa aws-load-balancer-controller -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
[[ -n "$SA_ROLE" ]] || die "ServiceAccount has no eks.amazonaws.com/role-arn annotation — IRSA not wired up"
ok "IRSA role: ${SA_ROLE}"

# -----------------------------------------------------------------------------
# 2. VPC ID (explicit beats auto-discovery — avoids a whole class of silent
#    "controller found the wrong VPC" failures on shared accounts)
# -----------------------------------------------------------------------------
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
ok "VPC: ${VPC_ID}"

# -----------------------------------------------------------------------------
# 3. CRDs — the eks-charts chart does NOT install these itself
# -----------------------------------------------------------------------------
log "Applying AWS Load Balancer Controller CRDs..."
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# -----------------------------------------------------------------------------
# 4. Install the controller
# -----------------------------------------------------------------------------
log "Installing aws-load-balancer-controller ${LBC_CHART_VERSION}..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$LBC_CHART_VERSION" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set createIngressClassResource=true \
  --set ingressClass=alb

log "Waiting for controller rollout..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

# -----------------------------------------------------------------------------
# 5. Subnet tag check — an ALB cannot be placed without these. eksctl tags
#    subnets it creates, but a pre-existing/imported VPC often is not tagged,
#    and the failure mode is a confusing "unable to discover subnets" event on
#    the Ingress rather than an error here.
# -----------------------------------------------------------------------------
log "Checking public subnets are tagged kubernetes.io/role/elb=1..."
TAGGED=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query 'length(Subnets)' --output text)

if [[ "$TAGGED" == "0" ]]; then
  printf '\033[1;33m[WARN]\033[0m  No subnets tagged kubernetes.io/role/elb=1 in %s.\n' "$VPC_ID"
  printf '           The ALB will fail to provision. Tag your public subnets:\n'
  printf '           aws ec2 create-tags --resources <subnet-id> --tags Key=kubernetes.io/role/elb,Value=1\n'
else
  ok "${TAGGED} subnet(s) tagged for internet-facing load balancers."
fi

ok "AWS Load Balancer Controller ready. Next: ./04-installEnvoy.sh"
