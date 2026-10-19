#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 06-installExternalDNS.sh — Install external-dns so Route53 A records for
# CJOC_HOST_NAME (and any other Gateway API HTTPRoute hostnames) are created
# and kept in sync automatically.
#
# PREREQUISITES
#   - Cluster already migrated to EKS Pod Identity
#     (eksctl utils migrate-to-pod-identity — see 01-createCluster.sh), which
#     installs the aws-eks-pod-identity-agent addon this script relies on.
#   - 03-installAwsLbController.sh already applied (provides the ALB).
#   - 04-installEnvoy.sh already applied (Gateway + cjoc-alb Ingress exist).
#   - A Route53 public hosted zone already exists for the domain that
#     CJOC_HOST_NAME belongs to (the same zone used for ACM DNS validation).
#   - Tools on PATH: aws (CLI v2), eksctl, kubectl, helm, jq
#
# WHAT THIS SCRIPT DOES
#   1. Resolves the Route53 hosted zone ID for the parent domain of
#      CJOC_HOST_NAME.
#   2. Creates a least-privilege IAM policy scoped to that hosted zone ID.
#   3. Creates an EKS Pod Identity association binding an IAM role (with that
#      policy) to the external-dns ServiceAccount.
#   4. Installs external-dns via Helm configured with:
#        - source: ingress (reads the hostname and the ALB address off the
#          cjoc-alb Ingress created by 04-installEnvoy.sh)
#
#          NOT gateway-httproute: the Envoy Service is now a ClusterIP behind
#          the ALB, so the Gateway's status address is a private cluster IP.
#          Using that source would publish A records pointing at an
#          unroutable address.
#        - provider: aws
#        - policy: sync
#        - txtOwnerId: unique per cluster, so external-dns only ever
#          touches records it created itself
#
# Usage: ./06-installExternalDNS.sh
# -----------------------------------------------------------------------------
set -euo pipefail
source ./.env



# Parent zone that owns CJOC_HOST_NAME. Override in .env if the zone apex
# isn't simply "strip the first label" (e.g. multi-level subdomains).
ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$CJOC_HOST_NAME")}"

TXT_OWNER_ID="${TXT_OWNER_ID:-${CLUSTER_NAME}}"

declare -A COMMON_TAGS=(
  [cb-user]="acaternberg"
  [cb-owner]="professional-services"
  [cb-environment]="demo"
)

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# =============================================================================
# 0. PRE-FLIGHT CHECKS
# =============================================================================
for bin in aws eksctl kubectl helm jq; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool '$bin' not found on PATH"
done

log "Verifying pod identity agent addon is installed..."
aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent \
  --region "$AWS_DEFAULT_REGION" >/dev/null 2>&1 \
  || die "eks-pod-identity-agent addon not found — run 'eksctl utils migrate-to-pod-identity' first"
ok "Pod identity agent present."

# =============================================================================
# 1. RESOLVE ROUTE53 HOSTED ZONE ID
# =============================================================================
log "Looking up hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE_DOMAIN}." \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
  --output text | sed 's#/hostedzone/##')

[[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] \
  || die "no public hosted zone found for '${ROUTE53_ZONE_DOMAIN}' — create it first, or set ROUTE53_ZONE_DOMAIN in .env"
ok "Hosted zone: ${HOSTED_ZONE_ID}"

# =============================================================================
# 2. IAM POLICY (scoped to this hosted zone only)
# =============================================================================
log "Checking for existing IAM policy '${EXTERNAL_DNS_POLICY_NAME}'..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${EXTERNAL_DNS_POLICY_NAME}"

if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "Creating IAM policy '${EXTERNAL_DNS_POLICY_NAME}' scoped to zone ${HOSTED_ZONE_ID}..."
  POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": ["arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}"]
    },
    {
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"],
      "Resource": ["*"]
    }
  ]
}
EOF
)
  aws iam create-policy \
    --policy-name "$EXTERNAL_DNS_POLICY_NAME" \
    --policy-document "$POLICY_DOC" \
    --tags $(for k in "${!COMMON_TAGS[@]}"; do echo -n "Key=${k},Value=${COMMON_TAGS[$k]} "; done) \
    >/dev/null
  ok "Policy created: ${POLICY_ARN}"
else
  ok "Policy already exists: ${POLICY_ARN}"
fi

# =============================================================================
# 3. NAMESPACE + SERVICEACCOUNT
# =============================================================================
log "Ensuring namespace '${NAMESPACE_EXTERNAL_DNS}' and ServiceAccount exist..."
kubectl create namespace "$NAMESPACE_EXTERNAL_DNS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE_EXTERNAL_DNS" \
  --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# 4. EKS POD IDENTITY ASSOCIATION (creates/reuses the IAM role for us)
# =============================================================================
log "Checking for existing pod identity association..."
EXISTING_ASSOC=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_DEFAULT_REGION" \
  --namespace "$NAMESPACE_EXTERNAL_DNS" \
  --query "associations[?serviceAccount=='${SERVICE_ACCOUNT_NAME}'].associationId | [0]" \
  --output text 2>/dev/null || true)

if [[ -z "$EXISTING_ASSOC" || "$EXISTING_ASSOC" == "None" ]]; then
  log "Creating pod identity association for ${NAMESPACE_EXTERNAL_DNS}/${SERVICE_ACCOUNT_NAME}..."
  eksctl create podidentityassociation \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_DEFAULT_REGION" \
    --namespace "$NAMESPACE_EXTERNAL_DNS" \
    --service-account-name "$SERVICE_ACCOUNT_NAME" \
    --role-name "$EXTERNAL_DNS_ROLE_NAME" \
    --permission-policy-arns "$POLICY_ARN"
  ok "Pod identity association created."
else
  ok "Pod identity association already exists (${EXISTING_ASSOC})."
fi

# =============================================================================
# 5. INSTALL EXTERNAL-DNS VIA HELM
# =============================================================================
log "Adding external-dns Helm repo..."
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ || true
helm repo update

log "Installing external-dns (source=ingress, domain=${ROUTE53_ZONE_DOMAIN})..."
helm upgrade --install external-dns external-dns/external-dns \
  --namespace "$NAMESPACE_EXTERNAL_DNS" \
  --version "$EXTERNAL_DNS_CHART_VERSION" \
  --set provider=aws \
  --set aws.region="$AWS_DEFAULT_REGION" \
  --set sources[0]=ingress \
  --set policy=sync \
  --set registry=txt \
  --set txtOwnerId="$TXT_OWNER_ID" \
  --set domainFilters[0]="$ROUTE53_ZONE_DOMAIN" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
  --set env[0].name=AWS_STS_REGIONAL_ENDPOINTS \
  --set env[0].value=regional

log "Waiting for external-dns rollout..."
kubectl rollout status deployment/external-dns -n "$NAMESPACE_EXTERNAL_DNS" --timeout=120s

echo
ok "Done. Summary:"
echo "  Hosted zone         : ${ROUTE53_ZONE_DOMAIN} (${HOSTED_ZONE_ID})"
echo "  TXT owner id        : ${TXT_OWNER_ID}"
echo "  Pod identity role   : ${EXTERNAL_DNS_ROLE_NAME}"
echo
echo "Verify the A record gets created for ${CJOC_HOST_NAME} (may take ~1 min):"
echo "  kubectl logs -n ${NAMESPACE_EXTERNAL_DNS} deploy/external-dns -f"
echo "  aws route53 list-resource-record-sets --hosted-zone-id ${HOSTED_ZONE_ID} \\"
echo "    --query \"ResourceRecordSets[?Name=='${CJOC_HOST_NAME}.']\""