#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteS3BackupBucket.sh — Teardown for 07-createS3BackupBucket.sh.
# DESTRUCTIVE: permanently deletes the bucket and ALL objects in it, plus the
# IAM policy (detached from every role using it, including the node role). The
# backup role and its Pod Identity associations are deleted only if the role has
# no other policy attached (e.g. the artifacts policy); otherwise they are kept.
# Asks for confirmation first.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${CLUSTER_NAME}-cbci-backup-${AWS_ACCOUNT_ID}}"
S3_BACKUP_POLICY_NAME="${S3_BACKUP_POLICY_NAME:-CBCI-S3Backup-Policy-${CLUSTER_NAME}}"
S3_BACKUP_ROLE_NAME="${S3_BACKUP_ROLE_NAME:-CBCI-S3Backup-Role-${CLUSTER_NAME}}"
S3_BACKUP_SA_NAMESPACE="${S3_BACKUP_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_BACKUP_POLICY_NAME}"

echo "This will permanently delete:"
echo "  - s3://${S3_BACKUP_BUCKET} and all its contents"
echo "  - IAM policy ${S3_BACKUP_POLICY_NAME} (detached from every role using it)"
echo "  - IAM role ${S3_BACKUP_ROLE_NAME} and its pod identity associations, if nothing else uses it"
read -r -p "Type the bucket name to confirm: " CONFIRM
[[ "${CONFIRM}" == "${S3_BACKUP_BUCKET}" ]] || error "Confirmation did not match; aborting."

# --- Detach the policy from every role, delete it ---
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  for ROLE in $(aws iam list-entities-for-policy --policy-arn "${POLICY_ARN}" \
      --query 'PolicyRoles[].RoleName' --output text); do
    log "Detaching ${S3_BACKUP_POLICY_NAME} from role ${ROLE}..."
    aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${POLICY_ARN}"
  done
  # delete-policy fails while non-default versions exist.
  for VERSION in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}"
  done
  log "Deleting IAM policy ${S3_BACKUP_POLICY_NAME}..."
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
fi

# --- Backup role + its associations (only if nothing else depends on it) ---
ROLE_ARN=$(aws iam get-role --role-name "${S3_BACKUP_ROLE_NAME}" \
  --query Role.Arn --output text 2>/dev/null || true)
if [[ -n "${ROLE_ARN}" && "${ROLE_ARN}" != "None" ]]; then
  REMAINING=$(aws iam list-attached-role-policies --role-name "${S3_BACKUP_ROLE_NAME}" \
    --query 'length(AttachedPolicies)' --output text)
  if [[ "${REMAINING}" -gt 0 ]]; then
    log "Role ${S3_BACKUP_ROLE_NAME} still has ${REMAINING} other policy(ies); keeping it and its associations."
  else
    for ASSOC in $(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" --namespace "${S3_BACKUP_SA_NAMESPACE}" \
        --query "associations[].associationId" --output text 2>/dev/null || true); do
      ASSOC_ROLE_ARN=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" --association-id "${ASSOC}" \
        --query association.roleArn --output text)
      if [[ "${ASSOC_ROLE_ARN}" == "${ROLE_ARN}" ]]; then
        log "Deleting pod identity association ${ASSOC}..."
        aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
          --region "${AWS_REGION}" --association-id "${ASSOC}" >/dev/null
      fi
    done
    log "Deleting IAM role ${S3_BACKUP_ROLE_NAME}..."
    aws iam delete-role --role-name "${S3_BACKUP_ROLE_NAME}"
  fi
fi

# --- Bucket ---
if aws s3api head-bucket --bucket "${S3_BACKUP_BUCKET}" 2>/dev/null; then
  log "Emptying and deleting bucket ${S3_BACKUP_BUCKET}..."
  aws s3 rm "s3://${S3_BACKUP_BUCKET}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "${S3_BACKUP_BUCKET}" --region "${AWS_REGION}"
fi

success "S3 backup resources removed."
