#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-createS3ArtifactStorage.sh — Create an S3 bucket for the CloudBees CI
# "Artifact Manager on S3" plugin and grant the controllers access to it via EKS
# Pod Identity (no static access keys).
# Teardown: 07-deleteS3ArtifactStorage.sh
#
# Based on https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/how-to-configure-artifact-s3-manager
# That article uses an IAM user with access keys and s3:* on *. This script
# replaces the keys with a Pod Identity role. The policy defaults to s3:* on THIS
# bucket only; set S3_ARTIFACTS_POLICY_SCOPE=any to get the article's s3:* on *
# (every bucket in the account becomes accessible to the ServiceAccount).
# s3:ListAllMyBuckets is always granted on *: the plugin's jclouds client lists
# buckets (GET /) when validating, and that action cannot be scoped to a bucket.
# It only exposes bucket names, not objects.
#
# Access is granted to the ServiceAccounts in ${S3_ARTIFACTS_SA_NAMES} (comma-
# separated) in ${S3_ARTIFACTS_SA_NAMESPACE}. A ServiceAccount with no Pod
# Identity association gets one to the artifacts role. One that already has an
# association keeps its role, and the artifacts policy is attached to that role
# (a ServiceAccount can only have one association).
#
# After running it, in each controller (Manage Jenkins > System > Artifact
# Management for Builds > Cloud Artifact Storage > Amazon S3) and
# Manage Jenkins > AWS: set the bucket name and base prefix printed below and
# leave the credentials unset so the plugin uses the default AWS credential chain
# (Pod Identity). Then validate the configuration.
#
# PREREQUISITES: aws CLI v2, a cluster created by 01-createCluster.sh, the EKS Pod
# Identity Agent addon, and the Artifact Manager on S3 plugin on the controllers.
# The controller pods must be (re)started after the association exists.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_ARTIFACTS_BUCKET="${S3_ARTIFACTS_BUCKET:-${CLUSTER_NAME}-cbci-artifacts-${AWS_ACCOUNT_ID}}"
S3_ARTIFACTS_PREFIX="${S3_ARTIFACTS_PREFIX-artifacts/}"   # base prefix set in the plugin; empty string = no prefix
S3_ARTIFACTS_EXPIRE_DAYS="${S3_ARTIFACTS_EXPIRE_DAYS:-30}"
S3_ARTIFACTS_POLICY_SCOPE="${S3_ARTIFACTS_POLICY_SCOPE:-bucket}"   # bucket | any
S3_ARTIFACTS_POLICY_NAME="${S3_ARTIFACTS_POLICY_NAME:-CBCI-S3Artifacts-Policy-${CLUSTER_NAME}}"
S3_ARTIFACTS_ROLE_NAME="${S3_ARTIFACTS_ROLE_NAME:-CBCI-S3Artifacts-Role-${CLUSTER_NAME}}"
S3_ARTIFACTS_SA_NAMES="${S3_ARTIFACTS_SA_NAMES:-controller1,hahs,plugable-storage}"   # comma-separated controller ServiceAccounts
S3_ARTIFACTS_SA_NAMESPACE="${S3_ARTIFACTS_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_ARTIFACTS_POLICY_NAME}"

case "${S3_ARTIFACTS_POLICY_SCOPE}" in
  bucket|any) ;;
  *) error "S3_ARTIFACTS_POLICY_SCOPE must be 'bucket' or 'any' (got '${S3_ARTIFACTS_POLICY_SCOPE}')" ;;
esac

TAGS_S3="TagSet=[{Key=cb-user,Value=${TAG_CB_USER}},{Key=cb-owner,Value=${TAG_CB_OWNER}},{Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}}]"
TAGS_IAM="Key=cb-user,Value=${TAG_CB_USER} Key=cb-owner,Value=${TAG_CB_OWNER} Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}"

# --- 1. Bucket ---------------------------------------------------------------
if aws s3api head-bucket --bucket "${S3_ARTIFACTS_BUCKET}" 2>/dev/null; then
  success "Bucket already exists: ${S3_ARTIFACTS_BUCKET}"
else
  log "Creating bucket ${S3_ARTIFACTS_BUCKET} in ${AWS_REGION}..."
  # us-east-1 rejects an explicit LocationConstraint.
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${S3_ARTIFACTS_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${S3_ARTIFACTS_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api wait bucket-exists --bucket "${S3_ARTIFACTS_BUCKET}"
  success "Bucket created."
fi

log "Blocking public access..."
aws s3api put-public-access-block --bucket "${S3_ARTIFACTS_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "Setting lifecycle: expire '${S3_ARTIFACTS_PREFIX}' objects after ${S3_ARTIFACTS_EXPIRE_DAYS} days..."
aws s3api put-bucket-lifecycle-configuration --bucket "${S3_ARTIFACTS_BUCKET}" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"expire-artifacts\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"${S3_ARTIFACTS_PREFIX}\"},
      \"Expiration\": {\"Days\": ${S3_ARTIFACTS_EXPIRE_DAYS}},
      \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
    }]
  }"

log "Tagging bucket..."
aws s3api put-bucket-tagging --bucket "${S3_ARTIFACTS_BUCKET}" --tagging "${TAGS_S3}"

# --- 2. IAM policy -----------------------------------------------------------
if [[ "${S3_ARTIFACTS_POLICY_SCOPE}" == "any" ]]; then
  log "WARNING: policy scope 'any' grants s3:* on * (every bucket in the account)."
  RESOURCES='"*"'
else
  RESOURCES="\"arn:aws:s3:::${S3_ARTIFACTS_BUCKET}\", \"arn:aws:s3:::${S3_ARTIFACTS_BUCKET}/*\""
fi

POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": [${RESOURCES}]
        },
        {
            "Effect": "Allow",
            "Action": "s3:ListAllMyBuckets",
            "Resource": "*"
        }
    ]
}
EOF
)

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
  log "Creating IAM policy ${S3_ARTIFACTS_POLICY_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-policy --policy-name "${S3_ARTIFACTS_POLICY_NAME}" \
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

if aws iam get-role --role-name "${S3_ARTIFACTS_ROLE_NAME}" >/dev/null 2>&1; then
  success "IAM role already exists: ${S3_ARTIFACTS_ROLE_NAME}"
else
  log "Creating IAM role ${S3_ARTIFACTS_ROLE_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-role --role-name "${S3_ARTIFACTS_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" --tags ${TAGS_IAM} >/dev/null
  success "IAM role created."
fi
# attach-role-policy is idempotent.
aws iam attach-role-policy --role-name "${S3_ARTIFACTS_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
ROLE_ARN=$(aws iam get-role --role-name "${S3_ARTIFACTS_ROLE_NAME}" --query Role.Arn --output text)

# --- 4. Pod Identity associations -------------------------------------------
# A ServiceAccount can have only one association (one role). If it already has
# one (e.g. the backup role), do NOT repoint it: that would drop its existing
# access. Attach the artifacts policy to the role it already uses instead.
IFS=',' read -r -a SA_LIST <<< "${S3_ARTIFACTS_SA_NAMES}"
for SA in "${SA_LIST[@]}"; do
  SA="${SA// /}"
  [[ -n "${SA}" ]] || continue

  EXISTING_ASSOC=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --namespace "${S3_ARTIFACTS_SA_NAMESPACE}" \
    --query "associations[?serviceAccount=='${SA}'].associationId | [0]" \
    --output text 2>/dev/null || true)

  if [[ -z "${EXISTING_ASSOC}" || "${EXISTING_ASSOC}" == "None" ]]; then
    log "Creating pod identity association for ${S3_ARTIFACTS_SA_NAMESPACE}/${SA}..."
    aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --namespace "${S3_ARTIFACTS_SA_NAMESPACE}" \
      --service-account "${SA}" --role-arn "${ROLE_ARN}" >/dev/null
    success "Association created for ${SA} (role ${S3_ARTIFACTS_ROLE_NAME})."
  else
    ASSOC_ROLE_ARN=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --association-id "${EXISTING_ASSOC}" \
      --query association.roleArn --output text)
    ASSOC_ROLE_NAME="${ASSOC_ROLE_ARN##*/}"
    if [[ "${ASSOC_ROLE_NAME}" == "${S3_ARTIFACTS_ROLE_NAME}" ]]; then
      success "${SA}: already uses ${ASSOC_ROLE_NAME}."
    else
      log "${SA}: already uses ${ASSOC_ROLE_NAME}; attaching the artifacts policy to it."
      # attach-role-policy is idempotent.
      aws iam attach-role-policy --role-name "${ASSOC_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
      success "${SA}: artifacts policy attached to ${ASSOC_ROLE_NAME}."
    fi
  fi
done

success "Artifact storage bucket ready."
echo "  Bucket:         s3://${S3_ARTIFACTS_BUCKET}"
echo "  Base prefix:    ${S3_ARTIFACTS_PREFIX:-<none>}"
echo "  Region:         ${AWS_REGION}"
echo "  IAM policy:     ${POLICY_ARN} (scope: ${S3_ARTIFACTS_POLICY_SCOPE})"
echo "  IAM role:       ${ROLE_ARN}"
echo "  ServiceAccounts: ${S3_ARTIFACTS_SA_NAMESPACE}/{${S3_ARTIFACTS_SA_NAMES}}"
log "Restart the controller pods, then set bucket and base prefix in Manage Jenkins > AWS (no credentials) and validate."
