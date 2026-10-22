#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteS3BackupBucket.sh — Teardown for 07-createS3BackupBucket.sh.
# DESTRUCTIVE: permanently deletes the bucket and ALL objects in it, plus the
# IAM policy (detached from the node role first). Asks for confirmation first.
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
S3_BACKUP_NODEGROUP="${S3_BACKUP_NODEGROUP:-controllers}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_BACKUP_POLICY_NAME}"

echo "This will permanently delete:"
echo "  - s3://${S3_BACKUP_BUCKET} and all its contents"
echo "  - IAM policy ${S3_BACKUP_POLICY_NAME} (detached from the '${S3_BACKUP_NODEGROUP}' node role)"
read -r -p "Type the bucket name to confirm: " CONFIRM
[[ "${CONFIRM}" == "${S3_BACKUP_BUCKET}" ]] || error "Confirmation did not match; aborting."

# --- Detach from node role, delete policy ---
NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${S3_BACKUP_NODEGROUP}" --region "${AWS_REGION}" \
  --query nodegroup.nodeRole --output text 2>/dev/null || true)
if [[ -n "${NODE_ROLE_ARN}" && "${NODE_ROLE_ARN}" != "None" ]]; then
  log "Detaching policy from ${NODE_ROLE_ARN##*/}..."
  aws iam detach-role-policy --role-name "${NODE_ROLE_ARN##*/}" --policy-arn "${POLICY_ARN}" 2>/dev/null || true
fi
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  log "Deleting IAM policy ${S3_BACKUP_POLICY_NAME}..."
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
fi

# --- Bucket ---
if aws s3api head-bucket --bucket "${S3_BACKUP_BUCKET}" 2>/dev/null; then
  log "Emptying and deleting bucket ${S3_BACKUP_BUCKET}..."
  aws s3 rm "s3://${S3_BACKUP_BUCKET}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "${S3_BACKUP_BUCKET}" --region "${AWS_REGION}"
fi

success "S3 backup resources removed."
