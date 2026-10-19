#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-stopEC2Instance.sh — Stop (not terminate) the standalone EC2 Client
# Controller instance created by 07-createEC2WithController.sh, to park it
# and save EC2 compute cost without tearing anything down.
#
# WHAT THIS DOES NOT TOUCH
#   The instance's security group, IAM role/instance profile, target group,
#   listener rule, ACM certificate, and Route53 record are all left in place
#   — same as a stopped instance normally behaves, this just makes the target
#   group report unhealthy until the instance is started again. The root EBS
#   volume (and whatever the Client Controller wrote under
#   /var/lib/cloudbees-client-controller) is untouched by a stop; it is only
#   at risk from termination (07-deleteEC2WithController.sh), not from this.
#
# WHAT THIS DOES NOT SAVE YOU
#   Stopping the instance stops its own EC2 compute charges only. You still
#   pay for: the attached EBS volume(s), the shared ALB, the EKS cluster and
#   its node groups (see 01-scaleDonwNodePools.sh for those), and the NAT
#   gateway. Nothing here scales the cluster down.
#
# Usage:
#   ./07-stopEC2Instance.sh              # stop and wait until it's stopped
#   ./07-stopEC2Instance.sh --no-wait    # request the stop, don't block
#   ./07-stopEC2Instance.sh --yes        # skip the confirmation prompt
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
  || error "no instance named '${EC2_INSTANCE_NAME}' found — nothing to stop"

STATE=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
success "Instance: ${INSTANCE_ID} (state: ${STATE})"

case "$STATE" in
  stopped)
    success "Already stopped — nothing to do."
    exit 0
    ;;
  stopping)
    log "Already stopping."
    ;;
  running)
    if [[ "$ASSUME_YES" != true ]]; then
      read -r -p "Stop instance ${INSTANCE_ID} (${EC2_INSTANCE_NAME})? [y/N] " reply
      [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
    fi
    log "Stopping ${INSTANCE_ID}..."
    aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    ;;
  *)
    error "instance is in state '${STATE}' — cannot stop from there (wait for it to finish transitioning)"
    ;;
esac

# =============================================================================
# 2. WAIT (OPTIONAL)
# =============================================================================
if [[ "$WAIT" == true ]]; then
  log "Waiting for ${INSTANCE_ID} to reach 'stopped'..."
  aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  success "Instance stopped."
else
  success "Stop requested — not waiting (--no-wait)."
fi

echo
log "Restart it with: aws ec2 start-instances --region ${AWS_REGION} --instance-ids ${INSTANCE_ID}"
