#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 06-deleteExternalDNS.sh — Teardown for 06-installExternalDNS.sh.
#
# ORDER MATTERS. Run this AFTER 04-deleteEnvoy.sh: external-dns (policy=sync)
# removes the Route53 records for the cjoc-alb Ingress once that Ingress is
# gone, but only while it is still running. This script therefore waits for the
# records to disappear BEFORE it uninstalls external-dns, and only deletes
# leftovers itself (records owned by this cluster's txtOwnerId) if the wait
# times out.
#
# WHAT THIS DELETES
#   - Route53 A/TXT records for CJOC_HOST_NAME owned by TXT_OWNER_ID (fallback)
#   - Helm release 'external-dns' and its namespace
#   - EKS Pod Identity association for the external-dns ServiceAccount
#   - IAM role EXTERNAL_DNS_ROLE_NAME (skipped if CloudFormation-managed, i.e.
#     created by eksctl: 01-deleteCluster.sh removes those with the cluster)
#   - IAM policy EXTERNAL_DNS_POLICY_NAME
#
# WHAT THIS DOES NOT DELETE
#   - The Route53 hosted zone, or any record not owned by this cluster.
#
# Usage:
#   ./06-deleteExternalDNS.sh          # prompts for confirmation
#   ./06-deleteExternalDNS.sh --yes    # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=true ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *)          error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

for bin in aws kubectl helm jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Must match 06-installExternalDNS.sh.
NAMESPACE_EXTERNAL_DNS="${NAMESPACE_EXTERNAL_DNS:-external-dns}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-external-dns}"
EXTERNAL_DNS_ROLE_NAME="${EXTERNAL_DNS_ROLE_NAME:-AmazonEKS_ExternalDNS_Role-${CLUSTER_NAME}}"
EXTERNAL_DNS_POLICY_NAME="${EXTERNAL_DNS_POLICY_NAME:-AmazonEKS_ExternalDNS_Policy-${CLUSTER_NAME}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${EXTERNAL_DNS_POLICY_NAME}"
ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$CJOC_HOST_NAME")}"
TXT_OWNER_ID="${TXT_OWNER_ID:-${CLUSTER_NAME}}"
WAIT_SECONDS="${EXTERNAL_DNS_WAIT_SECONDS:-180}"

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${ROUTE53_ZONE_DOMAIN}" \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text 2>/dev/null | sed 's|/hostedzone/||' || true)
[[ "${HOSTED_ZONE_ID}" == "None" ]] && HOSTED_ZONE_ID=""

# Records for CJOC_HOST_NAME (A/alias plus the TXT ownership records external-dns
# writes next to it, e.g. "<host>" and "a-<host>" / "cname-<host>").
cjoc_records() {
  [[ -n "${HOSTED_ZONE_ID}" ]] || return 0
  aws route53 list-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --output json \
    | jq -c --arg h "${CJOC_HOST_NAME}." '.ResourceRecordSets[]
        | select((.Name == $h or .Name == ("a-" + $h) or .Name == ("cname-" + $h) or .Name == ("aaaa-" + $h))
                 and (.Type == "A" or .Type == "AAAA" or .Type == "CNAME" or .Type == "TXT"))'
}

# =============================================================================
# 0. CONFIRM
# =============================================================================
echo
warn "About to delete:"
echo "    - Route53 records for ${CJOC_HOST_NAME} owned by '${TXT_OWNER_ID}' (if still present)"
echo "    - Helm release external-dns + namespace ${NAMESPACE_EXTERNAL_DNS}"
echo "    - Pod Identity association ${NAMESPACE_EXTERNAL_DNS}/${SERVICE_ACCOUNT_NAME}"
echo "    - IAM role ${EXTERNAL_DNS_ROLE_NAME} (unless CloudFormation-managed)"
echo "    - IAM policy ${EXTERNAL_DNS_POLICY_NAME}"
echo
if [[ "${ASSUME_YES}" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# =============================================================================
# 1. LET external-dns REMOVE ITS OWN RECORDS (needs the controller running)
# =============================================================================
CLUSTER_REACHABLE=false
kubectl get namespace "${NAMESPACE_EXTERNAL_DNS}" &>/dev/null && CLUSTER_REACHABLE=true

if [[ "${CLUSTER_REACHABLE}" == true && -n "${HOSTED_ZONE_ID}" ]]; then
  if kubectl get ingress cjoc-alb -n "${ENVOY_GW_NAMESPACE}" &>/dev/null; then
    warn "Ingress cjoc-alb still exists; external-dns will keep recreating the records. Run 04-deleteEnvoy.sh first."
  fi
  log "Waiting up to ${WAIT_SECONDS}s for external-dns to remove records for ${CJOC_HOST_NAME}..."
  waited=0
  until [[ -z "$(cjoc_records)" ]] || (( waited >= WAIT_SECONDS )); do
    sleep 10; waited=$((waited + 10))
  done
  [[ -z "$(cjoc_records)" ]] && success "external-dns removed the records." \
    || warn "Records still present after ${WAIT_SECONDS}s; deleting leftovers owned by '${TXT_OWNER_ID}'."
fi

# Fallback: delete leftover records. Only touch them if a TXT ownership record
# names our owner id, so records managed by someone else are never removed.
if [[ -n "${HOSTED_ZONE_ID}" ]]; then
  RECORDS=$(cjoc_records)
  if [[ -n "${RECORDS}" ]]; then
    if jq -e --arg o "external-dns/owner=${TXT_OWNER_ID}" \
        'select(.Type=="TXT") | .ResourceRecords[]?.Value | select(contains($o))' <<< "${RECORDS}" >/dev/null; then
      CHANGE=$(jq -s '{Changes: map({Action: "DELETE", ResourceRecordSet: .})}' <<< "${RECORDS}")
      aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" \
        --change-batch "${CHANGE}" >/dev/null
      success "Deleted leftover Route53 records for ${CJOC_HOST_NAME}."
    else
      warn "Records for ${CJOC_HOST_NAME} exist but no TXT record is owned by '${TXT_OWNER_ID}'; leaving them."
    fi
  fi
else
  warn "Hosted zone for ${ROUTE53_ZONE_DOMAIN} not found; skipping Route53 cleanup."
fi

# =============================================================================
# 2. HELM RELEASE + NAMESPACE
# =============================================================================
if helm status external-dns -n "${NAMESPACE_EXTERNAL_DNS}" &>/dev/null; then
  log "Uninstalling Helm release external-dns..."
  helm uninstall external-dns -n "${NAMESPACE_EXTERNAL_DNS}" --wait --timeout 5m
  success "Helm release removed."
else
  log "No external-dns Helm release found; skipping."
fi
kubectl delete namespace "${NAMESPACE_EXTERNAL_DNS}" --ignore-not-found --timeout=120s \
  || warn "Namespace deletion timed out."

# =============================================================================
# 3. POD IDENTITY ASSOCIATION
# =============================================================================
ASSOC_IDS=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" --namespace "${NAMESPACE_EXTERNAL_DNS}" \
  --query "associations[?serviceAccount=='${SERVICE_ACCOUNT_NAME}'].associationId" \
  --output text 2>/dev/null || true)
for id in ${ASSOC_IDS}; do
  [[ "${id}" == "None" ]] && continue
  log "Deleting Pod Identity association ${id}..."
  aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --association-id "${id}" --region "${AWS_REGION}" >/dev/null
  success "Association removed."
done

# =============================================================================
# 4. IAM ROLE + POLICY
# =============================================================================
if aws iam get-role --role-name "${EXTERNAL_DNS_ROLE_NAME}" &>/dev/null; then
  CFN_STACK=$(aws iam list-role-tags --role-name "${EXTERNAL_DNS_ROLE_NAME}" \
    --query "Tags[?Key=='aws:cloudformation:stack-name'].Value | [0]" --output text 2>/dev/null || true)
  if [[ -n "${CFN_STACK}" && "${CFN_STACK}" != "None" ]]; then
    log "Role ${EXTERNAL_DNS_ROLE_NAME} belongs to CloudFormation stack ${CFN_STACK}; 01-deleteCluster.sh removes it."
  else
    for arn in $(aws iam list-attached-role-policies --role-name "${EXTERNAL_DNS_ROLE_NAME}" \
        --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "${EXTERNAL_DNS_ROLE_NAME}" --policy-arn "${arn}"
    done
    for name in $(aws iam list-role-policies --role-name "${EXTERNAL_DNS_ROLE_NAME}" \
        --query 'PolicyNames[]' --output text); do
      aws iam delete-role-policy --role-name "${EXTERNAL_DNS_ROLE_NAME}" --policy-name "${name}"
    done
    aws iam delete-role --role-name "${EXTERNAL_DNS_ROLE_NAME}"
    success "IAM role ${EXTERNAL_DNS_ROLE_NAME} deleted."
  fi
else
  log "IAM role ${EXTERNAL_DNS_ROLE_NAME} not found; skipping."
fi

if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
  for role in $(aws iam list-entities-for-policy --policy-arn "${POLICY_ARN}" \
      --query 'PolicyRoles[].RoleName' --output text); do
    log "Detaching ${EXTERNAL_DNS_POLICY_NAME} from role ${role}..."
    aws iam detach-role-policy --role-name "${role}" --policy-arn "${POLICY_ARN}"
  done
  for v in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${v}"
  done
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
  success "IAM policy ${EXTERNAL_DNS_POLICY_NAME} deleted."
else
  log "IAM policy ${EXTERNAL_DNS_POLICY_NAME} not found; skipping."
fi

success "external-dns teardown complete."
