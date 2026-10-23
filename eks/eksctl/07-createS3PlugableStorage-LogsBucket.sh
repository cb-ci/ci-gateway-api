#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-createS3PlugableStorage-LogsBucket.sh — Create an S3 bucket for CloudBees CI
# Pluggable Storage (Pipeline build logs) and grant the pluggable storage service
# access to it via EKS Pod Identity.
# Teardown: 07-deleteS3PlugableStorage-LogsBucket.sh
#
# Follows https://docs.cloudbees.com/docs/cloudbees-ci/latest/pipelines/cloudbees-pluggable-storage
#   - IAM permissions: s3:ListBucket, s3:GetBucketLocation, s3:PutObject, s3:GetObject
#     (object access restricted to S3_LOGS_PREFIX when set). ListBucket carries no
#     s3:prefix condition: the service's HeadBucket health check sends no prefix
#     key, so a condition makes it fail with 403.
#   - The service runs as the ServiceAccount ${S3_LOGS_SA_NAME} in the operations
#     center namespace; the Helm chart creates it (05-installCloudBees.sh).
#
# PREREQUISITES: aws CLI v2, a cluster created by 01-createCluster.sh, the EKS Pod
# Identity Agent addon. The association can exist before the ServiceAccount; the
# pluggable storage pod must be (re)started after it exists to get credentials.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_LOGS_BUCKET="${S3_LOGS_BUCKET:-${CLUSTER_NAME}-cbci-logs-${AWS_ACCOUNT_ID}}"
S3_LOGS_PREFIX="${S3_LOGS_PREFIX-logs/builds/}"   # empty string = no prefix
S3_LOGS_EXPIRE_DAYS="${S3_LOGS_EXPIRE_DAYS:-30}"
S3_LOGS_POLICY_NAME="${S3_LOGS_POLICY_NAME:-CBCI-S3Logs-Policy-${CLUSTER_NAME}}"
S3_LOGS_ROLE_NAME="${S3_LOGS_ROLE_NAME:-CBCI-S3Logs-Role-${CLUSTER_NAME}}"
S3_LOGS_SA_NAME="${S3_LOGS_SA_NAME:-pluggable-storage-service}"
S3_LOGS_SA_NAMESPACE="${S3_LOGS_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_LOGS_POLICY_NAME}"

TAGS_S3="TagSet=[{Key=cb-user,Value=${TAG_CB_USER}},{Key=cb-owner,Value=${TAG_CB_OWNER}},{Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}}]"
TAGS_IAM="Key=cb-user,Value=${TAG_CB_USER} Key=cb-owner,Value=${TAG_CB_OWNER} Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}"

# --- 1. Bucket ---------------------------------------------------------------
if aws s3api head-bucket --bucket "${S3_LOGS_BUCKET}" 2>/dev/null; then
  success "Bucket already exists: ${S3_LOGS_BUCKET}"
else
  log "Creating bucket ${S3_LOGS_BUCKET} in ${AWS_REGION}..."
  # us-east-1 rejects an explicit LocationConstraint.
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${S3_LOGS_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${S3_LOGS_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api wait bucket-exists --bucket "${S3_LOGS_BUCKET}"
  success "Bucket created."
fi

log "Blocking public access..."
aws s3api put-public-access-block --bucket "${S3_LOGS_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "Setting lifecycle: expire '${S3_LOGS_PREFIX}' objects after ${S3_LOGS_EXPIRE_DAYS} days..."
aws s3api put-bucket-lifecycle-configuration --bucket "${S3_LOGS_BUCKET}" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"expire-build-logs\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"${S3_LOGS_PREFIX}\"},
      \"Expiration\": {\"Days\": ${S3_LOGS_EXPIRE_DAYS}},
      \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
    }]
  }"

log "Tagging bucket..."
aws s3api put-bucket-tagging --bucket "${S3_LOGS_BUCKET}" --tagging "${TAGS_S3}"

# --- 2. IAM policy (docs: "With prefix" / "Without prefix") ------------------
if [[ -n "${S3_LOGS_PREFIX}" ]]; then
  POLICY_DOC=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${S3_LOGS_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${S3_LOGS_BUCKET}/${S3_LOGS_PREFIX}*"
    }
  ]
}
POLICY
)
else
  POLICY_DOC=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${S3_LOGS_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${S3_LOGS_BUCKET}/*"
    }
  ]
}
POLICY
)
fi

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  # Keep the deployed policy in sync with POLICY_DOC. IAM allows 5 versions, so
  # drop the oldest non-default one first.
  log "IAM policy exists; publishing a new default version..."
  OLDEST_VERSION=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
    --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' --output text)
  VERSION_COUNT=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
    --query 'length(Versions)' --output text)
  if [[ "${VERSION_COUNT}" -ge 5 && "${OLDEST_VERSION}" != "None" ]]; then
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${OLDEST_VERSION}"
  fi
  aws iam create-policy-version --policy-arn "${POLICY_ARN}" \
    --policy-document "${POLICY_DOC}" --set-as-default >/dev/null
  success "IAM policy updated: ${POLICY_ARN}"
else
  log "Creating IAM policy ${S3_LOGS_POLICY_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-policy --policy-name "${S3_LOGS_POLICY_NAME}" \
    --policy-document "${POLICY_DOC}" --tags ${TAGS_IAM} >/dev/null
  success "IAM policy created."
fi

# --- 3. IAM role for EKS Pod Identity ---------------------------------------
TRUST_DOC='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "pods.eks.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}'

if aws iam get-role --role-name "${S3_LOGS_ROLE_NAME}" >/dev/null 2>&1; then
  success "IAM role already exists: ${S3_LOGS_ROLE_NAME}"
else
  log "Creating IAM role ${S3_LOGS_ROLE_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-role --role-name "${S3_LOGS_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" --tags ${TAGS_IAM} >/dev/null
  success "IAM role created."
fi
# attach-role-policy is idempotent.
aws iam attach-role-policy --role-name "${S3_LOGS_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
ROLE_ARN=$(aws iam get-role --role-name "${S3_LOGS_ROLE_NAME}" --query Role.Arn --output text)

# --- 4. Pod Identity association --------------------------------------------
EXISTING_ASSOC=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" --namespace "${S3_LOGS_SA_NAMESPACE}" \
  --query "associations[?serviceAccount=='${S3_LOGS_SA_NAME}'].associationId | [0]" \
  --output text 2>/dev/null || true)

if [[ -z "${EXISTING_ASSOC}" || "${EXISTING_ASSOC}" == "None" ]]; then
  log "Creating pod identity association for ${S3_LOGS_SA_NAMESPACE}/${S3_LOGS_SA_NAME}..."
  aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --namespace "${S3_LOGS_SA_NAMESPACE}" \
    --service-account "${S3_LOGS_SA_NAME}" --role-arn "${ROLE_ARN}" >/dev/null
  success "Pod identity association created."
else
  success "Pod identity association already exists (${EXISTING_ASSOC})."
fi

success "Pluggable storage logs bucket ready."
echo "  Bucket:         s3://${S3_LOGS_BUCKET}"
echo "  Prefix:         ${S3_LOGS_PREFIX:-<none>}"
echo "  IAM policy:     ${POLICY_ARN}"
echo "  IAM role:       ${ROLE_ARN}"
echo "  ServiceAccount: ${S3_LOGS_SA_NAMESPACE}/${S3_LOGS_SA_NAME}"
log "Enable it in the chart with S3_LOGS_ENABLED=true ./05-installCloudBees.sh, then restart the pluggable storage pod."
