#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-startEC2Instance.sh — Start the standalone EC2 Client Controller instance
# created by 07-createEC2WithController.sh, after it was parked with
# 07-stopEC2Instance.sh.
#
# WHAT THIS DOES NOT TOUCH
#   The instance's security group, IAM role/instance profile, target group,
#   listener rule, ACM certificate, and Route53 record are all left as-is —
#   starting the instance just makes the target group report healthy again
#   once the Client Controller comes back up.
#
# WHAT THIS DOES NOT COVER
#   This does not scale the EKS node groups back up (see
#   01-scaleDonwNodePools.sh's counterpart, if any) and does not verify the
#   Client Controller service inside the instance has come up — only that the
#   instance reached the 'running' state.
#
#   Once running (or if it was already running), this re-runs
#   07-createEC2WithController.sh to reassert the certificate attachment,
#   Ingress annotation, target group registration, and DNS record — all
#   idempotent, but necessary because the AWS Load Balancer Controller can
#   silently prune the ec2-controller ACM certificate from the shared ALB
#   listener on its own reconcile schedule, independent of this instance's
#   power state.
#
# Usage:
#   ./07-startEC2Instance.sh              # start and wait until it's running
#   ./07-startEC2Instance.sh --no-wait    # request the start, don't block
#   ./07-startEC2Instance.sh --yes        # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

for bin in aws; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

WAIT=true
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait)  WAIT=false ;;
    --yes|-y)   ASSUME_YES=true ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

# =============================================================================
# CONFIG — must match 07-createEC2WithController.sh so the same instance is
# targeted.
# =============================================================================
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
EC2_INSTANCE_NAME="${EC2_CONTROLLER_INSTANCE_NAME:-${CLUSTER_NAME}-ec2-controller}"

# =============================================================================
# 1. RESOLVE THE INSTANCE
# =============================================================================
log "Looking up instance '${EC2_INSTANCE_NAME}'..."
INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] \
  || error "no instance named '${EC2_INSTANCE_NAME}' found — nothing to start"

STATE=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
success "Instance: ${INSTANCE_ID} (state: ${STATE})"

ALREADY_RUNNING=false
case "$STATE" in
  running)
    success "Already running — nothing to do."
    ALREADY_RUNNING=true
    ;;
  pending)
    log "Already starting."
    ;;
  stopped)
    if [[ "$ASSUME_YES" != true ]]; then
      read -r -p "Start instance ${INSTANCE_ID} (${EC2_INSTANCE_NAME})? [y/N] " reply
      [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
    fi
    log "Starting ${INSTANCE_ID}..."
    aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    ;;
  *)
    error "instance is in state '${STATE}' — cannot start from there (wait for it to finish transitioning)"
    ;;
esac

# =============================================================================
# 2. WAIT (OPTIONAL)
# =============================================================================
if [[ "$WAIT" == true ]]; then
  if [[ "$ALREADY_RUNNING" != true ]]; then
    log "Waiting for ${INSTANCE_ID} to reach 'running'..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
    success "Instance running."
  fi

  log "Reasserting certificate attachment, Ingress annotation, target group, and DNS record (./07-createEC2WithController.sh, idempotent)..."
  ./07-createEC2WithController.sh
else
  success "Start requested — not waiting (--no-wait)."
  echo
  log "Once running, reassert cert/target-group/DNS wiring with: ./07-createEC2WithController.sh"
fi

echo
log "Stop it with: aws ec2 stop-instances --region ${AWS_REGION} --instance-ids ${INSTANCE_ID}"
