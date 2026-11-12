#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteS3ArtifactStorage.sh — Teardown for 07-createS3ArtifactStorage.sh.
# DESTRUCTIVE: permanently deletes the bucket and ALL objects in it (build
# artifacts), plus the IAM policy, the artifacts role and its Pod Identity
# associations. Asks for confirmation (--yes skips it).
#
# The artifacts and backup roles can be shared: a role is deleted (with its Pod
# Identity associations) only once no policy is attached to it. Otherwise the
# artifacts policy is just detached and the role keeps its other access.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true ;;
    *)        error "unknown flag '$1' (supported: --yes)" ;;
  esac
  shift
done

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_ARTIFACTS_BUCKET="${S3_ARTIFACTS_BUCKET:-${CLUSTER_NAME}-cbci-artifacts-${AWS_ACCOUNT_ID}}"
S3_ARTIFACTS_POLICY_NAME="${S3_ARTIFACTS_POLICY_NAME:-CBCI-S3Artifacts-Policy-${CLUSTER_NAME}}"
S3_ARTIFACTS_ROLE_NAME="${S3_ARTIFACTS_ROLE_NAME:-CBCI-S3Artifacts-Role-${CLUSTER_NAME}}"
S3_ARTIFACTS_SA_NAMESPACE="${S3_ARTIFACTS_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_ARTIFACTS_POLICY_NAME}"

echo "This will permanently delete:"
echo "  - s3://${S3_ARTIFACTS_BUCKET} and all its contents"
echo "  - IAM policy ${S3_ARTIFACTS_POLICY_NAME} (detached from every role using it)"
echo "  - IAM role ${S3_ARTIFACTS_ROLE_NAME} and its pod identity associations, if no other policy is attached"
if [[ "${ASSUME_YES}" != true ]]; then
  read -r -p "Type the bucket name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${S3_ARTIFACTS_BUCKET}" ]] || error "Confirmation did not match; aborting."
fi

# Deletes ROLE and the pod identity associations that use it, but only when no
# policy is attached any more (the backup and artifacts roles can be shared).
cleanup_role() {
  local role="$1" role_arn remaining assoc assoc_role_arn
  role_arn=$(aws iam get-role --role-name "${role}" --query Role.Arn --output text 2>/dev/null || true)
  [[ -n "${role_arn}" && "${role_arn}" != "None" ]] || return 0
  remaining=$(aws iam list-attached-role-policies --role-name "${role}" \
    --query 'length(AttachedPolicies)' --output text)
  if [[ "${remaining}" -gt 0 ]]; then
    log "Role ${role} still has ${remaining} other policy(ies); keeping it and its associations."
    return 0
  fi
  for assoc in $(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --namespace "${NS}" \
      --query "associations[].associationId" --output text 2>/dev/null || true); do
    assoc_role_arn=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --association-id "${assoc}" \
      --query association.roleArn --output text)
    if [[ "${assoc_role_arn}" == "${role_arn}" ]]; then
      log "Deleting pod identity association ${assoc}..."
      aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" --association-id "${assoc}" >/dev/null
    fi
  done
  log "Deleting IAM role ${role}..."
  aws iam delete-role --role-name "${role}"
}

# --- IAM policy: detach from every role (artifacts role + shared roles) ------
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  for ROLE in $(aws iam list-entities-for-policy --policy-arn "${POLICY_ARN}" \
      --query 'PolicyRoles[].RoleName' --output text); do
    log "Detaching ${S3_ARTIFACTS_POLICY_NAME} from role ${ROLE}..."
    aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${POLICY_ARN}"
  done
  # delete-policy fails while non-default versions exist.
  for VERSION in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}"
  done
  log "Deleting IAM policy ${S3_ARTIFACTS_POLICY_NAME}..."
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
fi

# --- IAM roles (only when nothing else is attached) ---------------------------
NS="${S3_ARTIFACTS_SA_NAMESPACE}"
cleanup_role "${S3_ARTIFACTS_ROLE_NAME}"
cleanup_role "${S3_BACKUP_ROLE_NAME:-CBCI-S3Backup-Role-${CLUSTER_NAME}}"

# --- Bucket ------------------------------------------------------------------
if aws s3api head-bucket --bucket "${S3_ARTIFACTS_BUCKET}" >/dev/null 2>&1; then
  log "Emptying and deleting bucket ${S3_ARTIFACTS_BUCKET}..."
  aws s3 rm "s3://${S3_ARTIFACTS_BUCKET}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "${S3_ARTIFACTS_BUCKET}" --region "${AWS_REGION}"
fi

success "Artifact storage resources removed."
