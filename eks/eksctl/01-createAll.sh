#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-createAll.sh — Orchestrates the COMPLETE creation of this environment by
# calling the numbered scripts in the order of the README "Execution Sequence".
# Counterpart of 09-deleteAll.sh.
#
# ORDER
#   1. Pre-flight: required tools, AWS credential check
#   2. 01-createCluster.sh
#   3. 02-create-efs-filesystem.sh                        (optional)
#   4. 03-installClusterAutoscaler.sh
#   5. 03-installAwsLbController.sh
#   6. 04-installEnvoy.sh
#   7. 07-createS3PlugableStorage-LogsBucket.sh           (optional; must precede 05)
#      07-createS3ArtifactStorage.sh                      (optional)
#   8. 05-installCloudBees.sh
#   9. 06-installExternalDNS.sh
#  10. 07-createEC2WithController.sh                      (optional)
#      08-createServiceAccountforRemoteAgents.sh          (optional)
#  11. 07-createS3BackupBucket.sh                         (optional; last, because it
#                                                          discovers controller ServiceAccounts)
#
# "Optional" steps run only with --install-optional-resources. Their effect inside
# 05-installCloudBees.sh (S3_LOGS_ENABLED, CASC_ENABLED, MCP_ENABLED, ...) is still
# controlled by .env.
#
# RE-RUNS
#   Steps that are NOT idempotent are detected and skipped when their resource
#   already exists: cluster, EFS, the three S3 buckets, EC2 controller, remote-agent
#   ServiceAccount. Helm-based steps (03, 04, 05, 06) use `helm upgrade --install`
#   and always run, so changed .env flags are applied.
#   The first failing step aborts the run; fix the cause and re-run.
#   Re-run 07-createS3BackupBucket.sh by hand after adding controllers.
#
# INTERACTION
#   Without --yes, every step is confirmed: [Y]es / [n]o (skip) / [q]uit.
#
# Usage:
#   ./01-createAll.sh                                  # core steps, ask per step
#   ./01-createAll.sh --install-optional-resources     # core + optional, ask per step
#   ./01-createAll.sh --yes                            # core steps, no questions
#   ./01-createAll.sh --install-optional-resources --yes
#   ./01-createAll.sh --dry-run [--install-optional-resources]   # print the plan only
# -----------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./.env

# Never open the AWS CLI pager (it blocks child scripts until "q" is pressed).
export AWS_PAGER=""

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
INSTALL_OPTIONAL=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)                      ASSUME_YES=true ;;
    --install-optional-resources)  INSTALL_OPTIONAL=true ;;
    --dry-run)                     DRY_RUN=true ;;
    -h|--help)                     sed -n '2,44p' "$0"; exit 0 ;;
    *)                             error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

for bin in aws eksctl kubectl helm jq envsubst; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# 00-login.sh only sources .env; authentication itself (e.g. `aws sso login`) is up to you.
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials not valid. Authenticate (e.g. 'aws sso login') and re-run."

# Names must match the create scripts' defaults (same as 09-deleteAll.sh).
EFS_NAME="${EFS_NAME:-${CLUSTER_NAME}-efs}"
EC2_INSTANCE_NAME="${EC2_CONTROLLER_INSTANCE_NAME:-${CLUSTER_NAME}-ec2-controller}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${CLUSTER_NAME}-cbci-backup-${AWS_ACCOUNT_ID}}"
S3_ARTIFACTS_BUCKET="${S3_ARTIFACTS_BUCKET:-${CLUSTER_NAME}-cbci-artifacts-${AWS_ACCOUNT_ID}}"
S3_LOGS_BUCKET="${S3_LOGS_BUCKET:-${CLUSTER_NAME}-cbci-logs-${AWS_ACCOUNT_ID}}"

# -----------------------------------------------------------------------------
# Existence checks (read-only). Return 0 when the resource already exists.
# -----------------------------------------------------------------------------
has_cluster() { aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; }
has_efs() {
  local id
  id=$(aws efs describe-file-systems --region "$AWS_REGION" \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId | [0]" \
        --output text 2>/dev/null || true)
  [[ -n "$id" && "$id" != "None" ]]
}
has_s3() { aws s3api head-bucket --bucket "$1" &>/dev/null; }
has_s3_logs()      { has_s3 "$S3_LOGS_BUCKET"; }
has_s3_artifacts() { has_s3 "$S3_ARTIFACTS_BUCKET"; }
has_s3_backup()    { has_s3 "$S3_BACKUP_BUCKET"; }
has_ec2() {
  local n
  n=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
  [[ "$n" != "0" && "$n" != "None" ]]
}
has_agent_sa() {
  kubectl get serviceaccount jenkins-agent -n cbci-builds --request-timeout=15s &>/dev/null
}

# -----------------------------------------------------------------------------
# Step table: label | command | kind (core|optional) | existence check (or "")
# -----------------------------------------------------------------------------
STEP_LABEL=(); STEP_CMD=(); STEP_KIND=(); STEP_CHECK=()
add_step() { STEP_LABEL+=("$1"); STEP_CMD+=("$2"); STEP_KIND+=("$3"); STEP_CHECK+=("$4"); }

add_step "EKS cluster, VPC, node groups"              "./01-createCluster.sh"                          core     has_cluster
add_step "EFS file system"                            "./02-create-efs-filesystem.sh"                  optional has_efs
add_step "Cluster Autoscaler"                         "./03-installClusterAutoscaler.sh"               core     ""
add_step "AWS Load Balancer Controller"               "./03-installAwsLbController.sh"                 core     ""
add_step "Envoy Gateway, shared ALB, ACM cert"        "./04-installEnvoy.sh"                           core     ""
add_step "S3 pluggable storage (build logs) bucket"   "./07-createS3PlugableStorage-LogsBucket.sh"    optional has_s3_logs
add_step "S3 artifact storage"                        "./07-createS3ArtifactStorage.sh"                optional has_s3_artifacts
add_step "CloudBees CI (Helm)"                        "./05-installCloudBees.sh"                       core     ""
add_step "ExternalDNS (Route53)"                      "./06-installExternalDNS.sh"                     core     ""
add_step "EC2 Client Controller"                      "./07-createEC2WithController.sh"                optional has_ec2
add_step "Remote-agent ServiceAccount"                "./08-createServiceAccountforRemoteAgents.sh"    optional has_agent_sa
add_step "S3 backup bucket (needs controllers)"       "./07-createS3BackupBucket.sh"                   optional has_s3_backup

for i in "${!STEP_CMD[@]}"; do
  [[ -f "${STEP_CMD[$i]}" ]] || error "missing script ${STEP_CMD[$i]}"
done

# -----------------------------------------------------------------------------
# Plan: decide per step whether it runs
# -----------------------------------------------------------------------------
STEP_RUN=()
echo
log "CREATE PLAN for cluster '${CLUSTER_NAME}' (account ${AWS_ACCOUNT_ID}, ${AWS_REGION})"
for i in "${!STEP_LABEL[@]}"; do
  label="${STEP_LABEL[$i]}"; check="${STEP_CHECK[$i]}"
  if [[ "${STEP_KIND[$i]}" == optional && "$INSTALL_OPTIONAL" != true ]]; then
    STEP_RUN+=(0); printf '  [skip]   %-45s (optional; use --install-optional-resources)\n' "$label"
  elif [[ -n "$check" ]] && "$check"; then
    STEP_RUN+=(0); printf '  [skip]   %-45s (already exists)\n' "$label"
  else
    STEP_RUN+=(1); printf '  [run]    %-45s %s\n' "$label" "${STEP_CMD[$i]}"
  fi
done
echo

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: nothing created."
  exit 0
fi

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------
trap 'echo; warn "Stopped at step: ${CURRENT_STEP:-?}. Fix the cause and re-run; finished steps are detected or can be skipped at the prompt."' ERR

for i in "${!STEP_LABEL[@]}"; do
  label="${STEP_LABEL[$i]}"; cmd="${STEP_CMD[$i]}"
  [[ "${STEP_RUN[$i]}" == 1 ]] || continue

  if [[ "$ASSUME_YES" != true ]]; then
    ANSWER=""
    while true; do
      read -r -p "Run '${label}' (${cmd})? [Y/n/q] " ANSWER
      case "${ANSWER:-y}" in
        y|Y|yes|YES) break ;;
        n|N|no|NO)   break ;;
        q|Q|quit)    warn "Aborted by user."; trap - ERR; exit 0 ;;
        *)           echo "Please answer y, n or q." ;;
      esac
    done
    if [[ "$ANSWER" =~ ^(n|N|no|NO)$ ]]; then
      warn "Skipped: ${label}"
      continue
    fi
  fi

  CURRENT_STEP="$label"
  echo
  log "=== ${label} ==="
  bash "$cmd"
  success "${label}: done."
done
trap - ERR

echo
success "Creation sequence finished."
