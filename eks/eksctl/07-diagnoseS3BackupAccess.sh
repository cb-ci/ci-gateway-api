#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-diagnoseS3BackupAccess.sh — READ-ONLY diagnosis of S3 backup AccessDenied
# for CloudBees CI managed controllers using EKS Pod Identity.
# Companion to 07-createS3BackupBucket.sh; changes nothing.
#
# For each controller pod (label ${S3_BACKUP_POD_SELECTOR} in ${S3_BACKUP_SA_NAMESPACE}):
#   ServiceAccount -> Pod Identity association -> role -> backup policy attached
#   -> pod started after association was created -> credentials injected in pod
#   -> IAM simulation of s3:PutObject on the backup bucket
# plus cluster-level checks (Pod Identity Agent addon/daemonset, bucket, policy).
#
# Usage: ./07-diagnoseS3BackupAccess.sh [pod-name ...]   (default: all controllers)
# Needs: aws CLI v2, kubectl. Optional: iam:SimulatePrincipalPolicy (else skipped).
# -----------------------------------------------------------------------------
set -uo pipefail

source ./.env

ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
FAILS=0

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "aws credentials not working"; exit 1; }

NS="${S3_BACKUP_SA_NAMESPACE:-cbci}"
SELECTOR="${S3_BACKUP_POD_SELECTOR:-com.cloudbees.cje.type=master}"
BUCKET="${S3_BACKUP_BUCKET:-${CLUSTER_NAME}-cbci-backup-${AWS_ACCOUNT_ID}}"
POLICY_NAME="${S3_BACKUP_POLICY_NAME:-CBCI-S3Backup-Policy-${CLUSTER_NAME}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

# --- cluster-level -----------------------------------------------------------
hdr "Cluster: ${CLUSTER_NAME} / namespace: ${NS} / bucket: ${BUCKET}"

if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then ok "bucket exists"
else bad "bucket ${BUCKET} not found or not accessible to your CLI identity"; fi

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then ok "policy exists: ${POLICY_NAME}"
else bad "policy ${POLICY_ARN} not found (run 07-createS3BackupBucket.sh)"; fi

ADDON_STATUS=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --addon-name eks-pod-identity-agent --query addon.status --output text 2>/dev/null || echo MISSING)
[[ "${ADDON_STATUS}" == "ACTIVE" ]] && ok "eks-pod-identity-agent addon ACTIVE" \
  || bad "eks-pod-identity-agent addon status: ${ADDON_STATUS}"

DS=$(kubectl -n kube-system get ds eks-pod-identity-agent \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
if [[ -z "${DS}" ]]; then bad "daemonset eks-pod-identity-agent not found"
elif [[ "${DS%/*}" == "${DS#*/}" ]]; then ok "daemonset ready: ${DS}"
else bad "daemonset not fully ready: ${DS}"; fi

# --- pods --------------------------------------------------------------------
if [[ $# -gt 0 ]]; then PODS="$*"
else PODS=$(kubectl -n "${NS}" get pods -l "${SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi
[[ -n "${PODS}" ]] || { bad "no pods found (selector '${SELECTOR}' in ${NS}); pass pod names as arguments"; exit 1; }

ASSOCS=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --namespace "${NS}" --query 'associations[].[serviceAccount,associationId]' --output text 2>/dev/null)

for POD in ${PODS}; do
  hdr "Pod ${NS}/${POD}"
  if ! kubectl -n "${NS}" get pod "${POD}" >/dev/null 2>&1; then bad "pod not found"; continue; fi

  SA=$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.serviceAccountName}')
  STARTED=$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.status.startTime}')
  NODE=$(kubectl -n "${NS}" get pod "${POD}" -o jsonpath='{.spec.nodeName}')
  info "serviceAccount=${SA} node=${NODE} started=${STARTED}"

  # Injected by the Pod Identity webhook at pod creation; absent => association
  # didn't exist when the pod was created (or the webhook didn't match the SA).
  ENVS=$(kubectl -n "${NS}" get pod "${POD}" \
    -o jsonpath='{range .spec.containers[*]}{range .env[*]}{.name}{"\n"}{end}{end}' | grep -E '^AWS_CONTAINER_(CREDENTIALS_FULL_URI|AUTHORIZATION_TOKEN_FILE)$' | sort -u | paste -sd, -)
  IRSA=$(kubectl -n "${NS}" get pod "${POD}" \
    -o jsonpath='{range .spec.containers[*]}{range .env[*]}{.name}{"\n"}{end}{end}' | grep -E '^AWS_(ROLE_ARN|WEB_IDENTITY_TOKEN_FILE)$' | sort -u | paste -sd, -)
  [[ -n "${IRSA}" ]] && info "IRSA env present (${IRSA}); it takes precedence over Pod Identity in the default chain"
  if [[ -n "${ENVS}" ]]; then ok "Pod Identity credentials injected (${ENVS})"
  else bad "no AWS_CONTAINER_* env in pod spec: pod started without a Pod Identity association"; fi

  # Association for this SA
  ASSOC_ID=$(printf '%s\n' "${ASSOCS}" | awk -v sa="${SA}" '$1==sa {print $2}')
  if [[ -z "${ASSOC_ID}" ]]; then
    bad "no Pod Identity association for SA '${SA}' (re-run: S3_BACKUP_SA_NAMES=${SA} ./07-createS3BackupBucket.sh)"
    continue
  fi
  read -r ROLE_ARN CREATED < <(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --association-id "${ASSOC_ID}" \
    --query 'association.[roleArn,createdAt]' --output text)
  ROLE_NAME="${ROLE_ARN##*/}"
  ok "association ${ASSOC_ID} -> ${ROLE_NAME} (created ${CREATED})"

  # Pod older than association => restart needed
  POD_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${STARTED}" +%s 2>/dev/null || date -u -d "${STARTED}" +%s 2>/dev/null || echo 0)
  ASSOC_EPOCH=$(date -u -d "${CREATED}" +%s 2>/dev/null || python3 -I -c "import sys,datetime as d;print(int(d.datetime.fromisoformat(sys.argv[1]).timestamp()))" "${CREATED}" 2>/dev/null || echo 0)
  if [[ "${POD_EPOCH}" -gt 0 && "${ASSOC_EPOCH}" -gt 0 && "${POD_EPOCH}" -lt "${ASSOC_EPOCH}" ]]; then
    bad "pod started BEFORE the association was created: restart the pod"
  fi

  # Backup policy on that role
  if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
       --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | grep -qx "${POLICY_ARN}"; then
    ok "backup policy attached to ${ROLE_NAME}"
  else
    bad "backup policy NOT attached to ${ROLE_NAME} (re-run 07-createS3BackupBucket.sh)"
  fi

  # Trust policy allows Pod Identity
  if aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.AssumeRolePolicyDocument' --output json \
       | grep -q 'pods.eks.amazonaws.com'; then ok "trust policy allows pods.eks.amazonaws.com"
  else bad "trust policy of ${ROLE_NAME} lacks pods.eks.amazonaws.com"; fi

  # Effective permission (includes any boundary/SCP-free identity evaluation)
  DECISION=$(aws iam simulate-principal-policy --policy-source-arn "${ROLE_ARN}" \
    --action-names s3:PutObject --resource-arns "arn:aws:s3:::${BUCKET}/cjoc-root-controllers/test" \
    --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo SKIPPED)
  case "${DECISION}" in
    allowed) ok "IAM simulation: s3:PutObject allowed for ${ROLE_NAME}" ;;
    SKIPPED) warn "IAM simulation skipped (missing iam:SimulatePrincipalPolicy?)" ;;
    *)       bad "IAM simulation: s3:PutObject ${DECISION} for ${ROLE_NAME}" ;;
  esac
done

hdr "Summary"
if [[ "${FAILS}" -eq 0 ]]; then
  ok "no failures. If backups still use the node role, the controller's S3 backup config/plugin may not use the default credential chain."
else
  bad "${FAILS} check(s) failed; see [FAIL] lines above"
fi
exit $(( FAILS > 0 ))
