#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-createS3BackupBucket.sh — Create an S3 bucket for CloudBees CI backups and
# grant every controller access to it via EKS Pod Identity.
# Teardown: 07-deleteS3BackupBucket.sh
#
# The requested permissions (s3:PutObject/GetObject/DeleteObject on the objects,
# s3:ListBucket on the bucket) have no Principal, so they are an IAM identity
# policy, not a bucket policy. It is attached to the role of each controller's
# ServiceAccount.
#
# Controller ServiceAccounts are DISCOVERED, so controllers can have any name:
# every ServiceAccount used by a pod labelled ${S3_BACKUP_POD_SELECTOR} in
# ${S3_BACKUP_SA_NAMESPACE} (the label CloudBees CI puts on managed controllers),
# plus any in ${S3_BACKUP_SA_NAMES} (comma-separated, optional).
#   - SA with no Pod Identity association: gets one to the backup role.
#   - SA that already has one (e.g. the artifacts role): keeps its role, and the
#     backup policy is attached to that role. A ServiceAccount can only have one
#     association, and Pod Identity credentials override the node role, so
#     changing the role would drop its other access.
# Pod Identity can't match names by wildcard: RE-RUN this script after adding a
# controller. Pods must be restarted after getting a new association.
#
# PREREQUISITES: aws CLI v2, kubectl pointed at the cluster, a cluster created by
# 01-createCluster.sh, and the EKS Pod Identity Agent addon.
# NOTE: this script no longer touches the node role. If an earlier version
# attached the backup policy there, detach it once every controller is covered:
#   aws iam detach-role-policy --role-name <node role> --policy-arn <policy arn>
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
S3_BACKUP_ROLE_NAME="${S3_BACKUP_ROLE_NAME:-CBCI-S3Backup-Role-${CLUSTER_NAME}}"
S3_BACKUP_SA_NAMESPACE="${S3_BACKUP_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
S3_BACKUP_POD_SELECTOR="${S3_BACKUP_POD_SELECTOR:-com.cloudbees.cje.type=master}"
S3_BACKUP_SA_NAMES="${S3_BACKUP_SA_NAMES:-}"   # extra ServiceAccounts, comma-separated
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
# Backups are uploaded with multipart upload: s3:PutObject covers starting and
# completing it, s3:AbortMultipartUpload lets the controller clean up a failure.
POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload"
            ],
            "Resource": "arn:aws:s3:::${S3_BACKUP_BUCKET}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::${S3_BACKUP_BUCKET}"
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
  log "Creating IAM policy ${S3_BACKUP_POLICY_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-policy --policy-name "${S3_BACKUP_POLICY_NAME}" \
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

if aws iam get-role --role-name "${S3_BACKUP_ROLE_NAME}" >/dev/null 2>&1; then
  success "IAM role already exists: ${S3_BACKUP_ROLE_NAME}"
else
  log "Creating IAM role ${S3_BACKUP_ROLE_NAME}..."
  # shellcheck disable=SC2086
  aws iam create-role --role-name "${S3_BACKUP_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" --tags ${TAGS_IAM} >/dev/null
  success "IAM role created."
fi
# attach-role-policy is idempotent.
aws iam attach-role-policy --role-name "${S3_BACKUP_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
ROLE_ARN=$(aws iam get-role --role-name "${S3_BACKUP_ROLE_NAME}" --query Role.Arn --output text)

# --- 4. Discover controller ServiceAccounts ----------------------------------
log "Discovering controller ServiceAccounts (pods '${S3_BACKUP_POD_SELECTOR}' in ${S3_BACKUP_SA_NAMESPACE})..."
DISCOVERED=$(kubectl -n "${S3_BACKUP_SA_NAMESPACE}" get pods -l "${S3_BACKUP_POD_SELECTOR}" \
  -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' 2>/dev/null || true)
SA_LIST=$(printf '%s\n%s\n' "${DISCOVERED}" "${S3_BACKUP_SA_NAMES//,/$'\n'}" \
  | tr -d ' ' | sed '/^$/d' | sort -u)
[[ -n "${SA_LIST}" ]] \
  || error "no controller ServiceAccounts found (selector '${S3_BACKUP_POD_SELECTOR}'); set S3_BACKUP_SA_NAMES or S3_BACKUP_POD_SELECTOR"
log "ServiceAccounts: $(echo "${SA_LIST}" | paste -sd, -)"

# --- 5. Pod Identity associations -------------------------------------------
# One association per SA. If it already has one, attach the backup policy to the
# role it uses instead of repointing it.
for SA in ${SA_LIST}; do
  EXISTING_ASSOC=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --namespace "${S3_BACKUP_SA_NAMESPACE}" \
    --query "associations[?serviceAccount=='${SA}'].associationId | [0]" \
    --output text 2>/dev/null || true)

  if [[ -z "${EXISTING_ASSOC}" || "${EXISTING_ASSOC}" == "None" ]]; then
    log "Creating pod identity association for ${S3_BACKUP_SA_NAMESPACE}/${SA}..."
    aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --namespace "${S3_BACKUP_SA_NAMESPACE}" \
      --service-account "${SA}" --role-arn "${ROLE_ARN}" >/dev/null
    success "${SA}: association created (role ${S3_BACKUP_ROLE_NAME})."
  else
    ASSOC_ROLE_ARN=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --association-id "${EXISTING_ASSOC}" \
      --query association.roleArn --output text)
    ASSOC_ROLE_NAME="${ASSOC_ROLE_ARN##*/}"
    if [[ "${ASSOC_ROLE_NAME}" == "${S3_BACKUP_ROLE_NAME}" ]]; then
      success "${SA}: already uses ${ASSOC_ROLE_NAME}."
    else
      log "${SA}: already uses ${ASSOC_ROLE_NAME}; attaching the backup policy to it."
      aws iam attach-role-policy --role-name "${ASSOC_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
      success "${SA}: backup policy attached to ${ASSOC_ROLE_NAME}."
    fi
  fi
done

success "S3 backup bucket ready."
echo "  Bucket:      s3://${S3_BACKUP_BUCKET}"
echo "  IAM policy:  ${POLICY_ARN}"
echo "  IAM role:    ${ROLE_ARN}"
echo "  ServiceAccounts: ${S3_BACKUP_SA_NAMESPACE}/{$(echo "${SA_LIST}" | paste -sd, -)}"
log "Restart controller pods that just got a new association. Re-run this script after adding a controller."
