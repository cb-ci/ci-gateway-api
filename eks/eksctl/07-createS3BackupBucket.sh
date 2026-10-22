#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-createS3BackupBucket.sh — Create an S3 bucket for CloudBees CI backups and
# grant access to it by attaching the policy to the node IAM role of the
# controllers node group.
# Teardown: 07-deleteS3BackupBucket.sh
#
# The requested permissions (s3:PutObject/GetObject/DeleteObject on the objects,
# s3:ListBucket on the bucket) have no Principal, so they are an IAM identity
# policy, not a bucket policy. They are created as a customer-managed IAM policy
# and attached to the node role of the node group ${S3_BACKUP_NODEGROUP}.
#
# SECURITY NOTE: every pod on those nodes (all controllers, and anything else
# scheduled there) inherits this access. Per-controller access would need one EKS
# Pod Identity association per ServiceAccount instead.
#
# PREREQUISITES: aws CLI v2, a cluster created by 01-createCluster.sh. No pod
# restart is needed; pods pick up node role changes via instance metadata.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${CLUSTER_NAME}-cbci-backup-${AWS_ACCOUNT_ID}}"
S3_BACKUP_EXPIRE_DAYS="${S3_BACKUP_EXPIRE_DAYS:-30}"
S3_BACKUP_POLICY_NAME="${S3_BACKUP_POLICY_NAME:-CBCI-S3Backup-Policy-${CLUSTER_NAME}}"
S3_BACKUP_NODEGROUP="${S3_BACKUP_NODEGROUP:-controllers}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_BACKUP_POLICY_NAME}"

TAGS_S3="TagSet=[{Key=cb-user,Value=${TAG_CB_USER}},{Key=cb-owner,Value=${TAG_CB_OWNER}},{Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}}]"
TAGS_IAM="Key=cb-user,Value=${TAG_CB_USER} Key=cb-owner,Value=${TAG_CB_OWNER} Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}"

# --- 1. Bucket ---------------------------------------------------------------
if aws s3api head-bucket --bucket "${S3_BACKUP_BUCKET}" 2>/dev/null; then
  success "Bucket already exists: ${S3_BACKUP_BUCKET}"
else
  log "Creating bucket ${S3_BACKUP_BUCKET} in ${AWS_REGION}..."
  # us-east-1 rejects an explicit LocationConstraint.
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${S3_BACKUP_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${S3_BACKUP_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api wait bucket-exists --bucket "${S3_BACKUP_BUCKET}"
  success "Bucket created."
fi

log "Blocking public access..."
aws s3api put-public-access-block --bucket "${S3_BACKUP_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "Setting lifecycle: expire objects after ${S3_BACKUP_EXPIRE_DAYS} days..."
aws s3api put-bucket-lifecycle-configuration --bucket "${S3_BACKUP_BUCKET}" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"expire-backups\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"\"},
      \"Expiration\": {\"Days\": ${S3_BACKUP_EXPIRE_DAYS}},
      \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
    }]
  }"

log "Tagging bucket..."
aws s3api put-bucket-tagging --bucket "${S3_BACKUP_BUCKET}" --tagging "${TAGS_S3}"

# --- 2. IAM policy -----------------------------------------------------------
POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${S3_BACKUP_BUCKET}/*"
        },
        {
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::${S3_BACKUP_BUCKET}"
        }
    ]
}
EOF
)

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  success "IAM policy already exists: ${POLICY_ARN}"
else
  log "Creating IAM policy ${S3_BACKUP_POLICY_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-policy --policy-name "${S3_BACKUP_POLICY_NAME}" \
    --policy-document "${POLICY_DOC}" --tags ${TAGS_IAM} >/dev/null
  success "IAM policy created."
fi

# --- 3. Attach the policy to the node role -----------------------------------
log "Resolving node role of node group '${S3_BACKUP_NODEGROUP}'..."
NODE_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${S3_BACKUP_NODEGROUP}" --region "${AWS_REGION}" \
  --query nodegroup.nodeRole --output text 2>/dev/null || true)
[[ -n "${NODE_ROLE_ARN}" && "${NODE_ROLE_ARN}" != "None" ]] \
  || error "node group '${S3_BACKUP_NODEGROUP}' not found in cluster '${CLUSTER_NAME}'"
NODE_ROLE_NAME="${NODE_ROLE_ARN##*/}"

# attach-role-policy is idempotent.
aws iam attach-role-policy --role-name "${NODE_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
success "Policy attached to node role ${NODE_ROLE_NAME}."

success "S3 backup bucket ready."
echo "  Bucket:      s3://${S3_BACKUP_BUCKET}"
echo "  IAM policy:  ${POLICY_ARN}"
echo "  Node role:   ${NODE_ROLE_ARN}"
log "Pods on node group '${S3_BACKUP_NODEGROUP}' can use the bucket (may take a minute to propagate)."
