#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-createEC2WithController.sh — Provision a standalone EC2 instance running a
# CloudBees CI Client Controller, fronted by the SAME shared ALB that
# 04-installEnvoy.sh already created for the in-cluster Operations Center
# (host-header routing: cjoc.<domain> -> Envoy/EKS, ec2-controller.<domain> ->
# this EC2 instance).
#
# PREREQUISITES
#   - 01-createCluster.sh already run (VPC/subnets exist, tagged by eksctl).
#   - 03-installAwsLbController.sh + 04-installEnvoy.sh already run (the
#     "cjoc-alb" Ingress/ALB must already exist — this script reuses it rather
#     than creating a second ALB).
#   - A Route53 public hosted zone already exists for the parent domain of
#     EC2_HOST_NAME (same zone used for CJOC's ACM DNS validation).
#   - Tools on PATH: aws (CLI v2), kubectl, jq
#
# WHAT THIS SCRIPT DOES
#   1. Resolves the existing VPC / a private subnet used by the EKS cluster.
#   2. Resolves the existing shared ALB (from the cjoc-alb Ingress), its
#      security group, HTTPS listener and canonical hosted zone.
#   3. Creates (or reuses) a Security Group for the EC2 instance: 8080/80/443
#      from the ALB's security group only, 22 from the VPC CIDR. Also allows
#      this instance to reach the EKS API server (443) via the cluster's
#      security group, since the cluster's private endpoint access means that
#      path is not otherwise open to it.
#   4. Creates (or reuses) an IAM role + instance profile
#      (AmazonSSMManagedInstanceCore, for Session Manager access).
#   5. Requests/reuses an ACM certificate for EC2_HOST_NAME and attaches it to
#      the shared ALB's HTTPS listener (SNI) if not already attached.
#   6. Launches (or reuses) an Amazon Linux 2023 EC2 instance in the private
#      subnet with userData that installs Java 21, Docker, and a
#      systemd-managed CloudBees CI Client Controller container bound to
#      localhost:8080.
#   7. Creates (or reuses) a Target Group (port 8080) + registers the instance,
#      and adds a host-header listener rule on the shared ALB.
#   8. Upserts a Route53 alias A record for EC2_HOST_NAME -> the shared ALB.
#
# ASSUMPTIONS FLAGGED (verify before relying on them)
#   - CLOUDBEES_CONTROLLER_IMAGE defaults to a placeholder tag. Confirm the
#     correct CloudBees CI Client Controller image/tag for your licensed
#     version and override via .env before running in anything but a demo.
#   - Attaching this EC2-hosted controller to the existing Operations Center
#     (CJOC) as a managed "Client Controller" still requires the manual/CasC
#     "Add Controller" step in CJOC (it needs a controller-specific token this
#     script has no way to obtain) — this script only stands up the box and
#     network path up to a working http://<instance>:8080/ endpoint.
#
# Usage: ./07-createEC2WithController.sh
# -----------------------------------------------------------------------------
set -euo pipefail

# Load environment variables (same convention as 01-06)
source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

for bin in aws kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# =============================================================================
# CONFIG (all overridable via .env)
# =============================================================================
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
EC2_HOST_NAME="${EC2_CONTROLLER_HOST_NAME:-ec2-controller.acaternberg.aws.ps.beescloud.com}"
EC2_INSTANCE_NAME="${EC2_CONTROLLER_INSTANCE_NAME:-${CLUSTER_NAME}-ec2-controller}"
EC2_INSTANCE_TYPE="${EC2_CONTROLLER_INSTANCE_TYPE:-t3.medium}"
EC2_VOLUME_SIZE_GB="${EC2_CONTROLLER_VOLUME_SIZE:-50}"
EC2_CONTROLLER_PORT="${EC2_CONTROLLER_PORT:-8080}"
EC2_KEY_NAME="${EC2_CONTROLLER_KEY_NAME:-}"          # optional; SSM Session Manager works without one
CLOUDBEES_CONTROLLER_IMAGE="${CLOUDBEES_CONTROLLER_IMAGE:-cloudbees/cloudbees-core-cm:latest}"

ENVOY_GW_NAMESPACE="${ENVOY_GW_NAMESPACE:?ENVOY_GW_NAMESPACE must be set in .env (namespace of the existing cjoc-alb Ingress)}"

TAG_CB_USER="${TAG_CB_USER:-acaternberg}"
TAG_CB_OWNER="${TAG_CB_OWNER:-professional-services}"
TAG_CB_ENVIRONMENT="${TAG_CB_ENVIRONMENT:-demo}"
# Each tag must be its own {Key=...,Value=...} map in the shorthand Tags=[...]
# list -- a flat "Key=k,Value=v" string (with commas swapped for spaces later)
# parses as a list of strings instead of a list of maps and run-instances
# rejects it with a ParamValidation error.
TAG_SPEC="{Key=Name,Value=${EC2_INSTANCE_NAME}},{Key=cb-user,Value=${TAG_CB_USER}},{Key=cb-owner,Value=${TAG_CB_OWNER}},{Key=cb-environment,Value=${TAG_CB_ENVIRONMENT}}"

ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$EC2_HOST_NAME")}"

IAM_ROLE_NAME="${EC2_INSTANCE_NAME}-role"
IAM_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_NAME}-profile"
SG_NAME="${EC2_INSTANCE_NAME}-sg"
TG_NAME="${EC2_INSTANCE_NAME}-tg"

# =============================================================================
# 1. VPC + SUBNET (reuse what the EKS cluster already has)
# =============================================================================
log "Resolving VPC for cluster '${CLUSTER_NAME}'..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || error "could not resolve VPC for cluster ${CLUSTER_NAME}"
success "VPC: ${VPC_ID}"

VPC_CIDR=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)
ADMIN_SSH_CIDR="${EC2_CONTROLLER_SSH_CIDR:-$VPC_CIDR}"

log "Resolving a private subnet in ${VPC_ID}..."
SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  warn "No subnet tagged kubernetes.io/role/internal-elb=1 found; falling back to any subnet in the VPC."
  SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[0].SubnetId' --output text)
fi
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]] || error "no subnet found in VPC ${VPC_ID}"
success "Subnet: ${SUBNET_ID}"

# =============================================================================
# 2. RESOLVE THE EXISTING SHARED ALB (created by 04-installEnvoy.sh)
# =============================================================================
log "Resolving shared ALB from Ingress cjoc-alb (namespace ${ENVOY_GW_NAMESPACE})..."
ALB_DNS=$(kubectl get ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
[[ -n "$ALB_DNS" ]] || error "cjoc-alb Ingress has no address yet — run 04-installEnvoy.sh first"
success "Shared ALB: ${ALB_DNS}"

ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn | [0]" --output text)
[[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]] || error "could not resolve ALB ARN for DNS name ${ALB_DNS}"

ALB_SG_ID=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
ALB_CANONICAL_ZONE_ID=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text)
[[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]] || error "shared ALB has no HTTPS (443) listener yet"
success "ALB SG: ${ALB_SG_ID} | HTTPS listener resolved."

# =============================================================================
# 3. SECURITY GROUP FOR THE EC2 INSTANCE
# =============================================================================
log "Checking for existing security group '${SG_NAME}'..."
EC2_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [[ -z "$EC2_SG_ID" || "$EC2_SG_ID" == "None" ]]; then
  log "Creating security group '${SG_NAME}'..."
  EC2_SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" --description "CloudBees CI Client Controller EC2 instance (${EC2_HOST_NAME})" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)

  aws ec2 create-tags --region "$AWS_REGION" --resources "$EC2_SG_ID" \
    --tags Key=Name,Value="$SG_NAME" Key=cb-user,Value="$TAG_CB_USER" \
           Key=cb-owner,Value="$TAG_CB_OWNER" Key=cb-environment,Value="$TAG_CB_ENVIRONMENT" >/dev/null

  log "Authorizing inbound from ALB SG (${ALB_SG_ID}) on ${EC2_CONTROLLER_PORT}/80/443..."
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$EC2_SG_ID" \
    --source-group "$ALB_SG_ID" --protocol tcp --port "$EC2_CONTROLLER_PORT" >/dev/null
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$EC2_SG_ID" \
    --source-group "$ALB_SG_ID" --protocol tcp --port 80 >/dev/null
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$EC2_SG_ID" \
    --source-group "$ALB_SG_ID" --protocol tcp --port 443 >/dev/null

  log "Authorizing inbound SSH (22) from ${ADMIN_SSH_CIDR}..."
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$EC2_SG_ID" \
    --cidr "$ADMIN_SSH_CIDR" --protocol tcp --port 22 >/dev/null
  # Outbound: default SG egress (all traffic) already applies — nothing to add.
  success "Security group created: ${EC2_SG_ID}"
else
  success "Security group already exists: ${EC2_SG_ID}"
fi

# =============================================================================
# 3b. EKS API ACCESS — allow this instance to reach the K8s API server (443)
# =============================================================================
# Not needed for the Client Controller container itself (it only talks to
# CJOC over HTTP, never the K8s API), but this instance lives inside the same
# VPC as the cluster, and eksctl-config.yaml sets
# clusterEndpoints.privateAccess: true. That means any client inside the VPC
# — including this instance — resolves CLUSTER_NAME's API endpoint to a
# private ENI IP gated by the EKS-managed "cluster security group", not by
# internet routing. publicAccess: true does not help here: this instance
# never takes the public path once private access is enabled. Without this
# rule, `kubectl`/`curl` from this instance times out even though outbound
# internet access (via the NAT gateway) works fine for everything else.
log "Resolving EKS cluster security group..."
CLUSTER_SG_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
[[ -n "$CLUSTER_SG_ID" && "$CLUSTER_SG_ID" != "None" ]] || error "could not resolve cluster security group for ${CLUSTER_NAME}"
success "Cluster security group: ${CLUSTER_SG_ID}"

log "Checking whether ${CLUSTER_SG_ID} already allows 443 from ${SG_NAME}..."
ALREADY_ALLOWED=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$CLUSTER_SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`443\` && FromPort==\`443\`][].UserIdGroupPairs[] | [?GroupId=='${EC2_SG_ID}']" \
  --output text)

if [[ -z "$ALREADY_ALLOWED" ]]; then
  log "Authorizing ${SG_NAME} -> EKS API (443) on cluster security group ${CLUSTER_SG_ID}..."
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CLUSTER_SG_ID" \
    --protocol tcp --port 443 --source-group "$EC2_SG_ID" >/dev/null
  success "Cluster security group now allows ${SG_NAME} on 443."
else
  success "Cluster security group already allows ${SG_NAME} on 443."
fi

# =============================================================================
# 4. IAM ROLE + INSTANCE PROFILE
# =============================================================================
log "Checking for existing IAM role '${IAM_ROLE_NAME}'..."
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  log "Creating IAM role '${IAM_ROLE_NAME}'..."
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --tags Key=cb-user,Value="$TAG_CB_USER" Key=cb-owner,Value="$TAG_CB_OWNER" Key=cb-environment,Value="$TAG_CB_ENVIRONMENT" \
    >/dev/null
  success "IAM role created: ${IAM_ROLE_NAME}"
else
  success "IAM role already exists: ${IAM_ROLE_NAME}"
fi

# SSM access (Session Manager) so SSH is a fallback, not the only way in.
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null

log "Checking for existing instance profile '${IAM_INSTANCE_PROFILE_NAME}'..."
if ! aws iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null
  success "Instance profile created: ${IAM_INSTANCE_PROFILE_NAME}"
  log "Waiting for IAM instance profile propagation..."
  sleep 15
else
  success "Instance profile already exists: ${IAM_INSTANCE_PROFILE_NAME}"
fi

# =============================================================================
# 5. ACM CERTIFICATE FOR EC2_HOST_NAME (reuse existing 04-installEnvoy.sh logic)
# =============================================================================
log "Checking for an ISSUED ACM certificate for '${EC2_HOST_NAME}' in '${AWS_REGION}'..."
ACM_CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
  --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='${EC2_HOST_NAME}'].CertificateArn | [0]" --output text 2>/dev/null || true)

if [[ -z "$ACM_CERT_ARN" || "$ACM_CERT_ARN" == "None" ]]; then
  log "No issued certificate found. Requesting an Amazon-issued ACM certificate..."
  ACM_CERT_ARN=$(aws acm request-certificate --region "$AWS_REGION" \
    --domain-name "$EC2_HOST_NAME" \
    --validation-method DNS \
    --tags Key=Name,Value="${EC2_HOST_NAME}-acm-cert" Key=cb-user,Value="$TAG_CB_USER" Key=cb-owner,Value="$TAG_CB_OWNER" Key=cb-environment,Value="$TAG_CB_ENVIRONMENT" \
    --query "CertificateArn" --output text)
  success "Requested certificate: ${ACM_CERT_ARN}"

  log "Waiting for ACM to publish the DNS validation record..."
  VALIDATION_NAME=""; VALIDATION_VALUE=""
  for _ in $(seq 1 30); do
    read -r VALIDATION_NAME VALIDATION_VALUE < <(aws acm describe-certificate \
      --region "$AWS_REGION" --certificate-arn "$ACM_CERT_ARN" \
      --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
      --output text 2>/dev/null || echo "")
    [[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] && break
    sleep 5
  done
  [[ -n "$VALIDATION_NAME" && "$VALIDATION_NAME" != "None" ]] \
    || error "ACM never returned a validation record for ${ACM_CERT_ARN}"

  log "Resolving hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "${ROUTE53_ZONE_DOMAIN}." \
    --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
    --output text | sed 's#/hostedzone/##')
  [[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] \
    || error "no public hosted zone for '${ROUTE53_ZONE_DOMAIN}' — create it, or set ROUTE53_ZONE_DOMAIN in .env"

  log "Upserting validation CNAME ${VALIDATION_NAME} into zone ${HOSTED_ZONE_ID}..."
  aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${VALIDATION_NAME}\",
          \"Type\": \"CNAME\",
          \"TTL\": 60,
          \"ResourceRecords\": [{\"Value\": \"${VALIDATION_VALUE}\"}]
        }
      }]
    }" >/dev/null

  log "Waiting for ACM to validate and issue (typically 2-5 min)..."
  aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn "$ACM_CERT_ARN" \
    || error "certificate ${ACM_CERT_ARN} was not issued — check DNS propagation and ACM console"
  success "Certificate issued: ${ACM_CERT_ARN}"
else
  success "Found issued certificate: ${ACM_CERT_ARN}"
fi

log "Ensuring certificate is attached to the shared ALB's HTTPS listener..."
ALREADY_ATTACHED=$(aws elbv2 describe-listener-certificates --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
  --query "Certificates[?CertificateArn=='${ACM_CERT_ARN}'] | length(@)" --output text)
if [[ "$ALREADY_ATTACHED" == "0" ]]; then
  aws elbv2 add-listener-certificates --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
    --certificates CertificateArn="$ACM_CERT_ARN" >/dev/null
  success "Certificate attached to listener."
else
  success "Certificate already attached to listener."
fi

# The AWS Load Balancer Controller treats the cjoc-alb Ingress's
# certificate-arn annotation as the FULL desired certificate set for this
# listener and prunes anything else on its next reconcile (controller
# restart, any Ingress edit, periodic resync) — even though the direct
# attach above just worked. Fold this ARN into that annotation so the
# controller keeps it attached instead of stripping it back off.
log "Ensuring certificate is declared on the cjoc-alb Ingress (so the AWS Load Balancer Controller keeps it, instead of pruning it on reconcile)..."
CURRENT_CERT_ARNS=$(kubectl get ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')
if [[ ",${CURRENT_CERT_ARNS}," == *",${ACM_CERT_ARN},"* ]]; then
  success "Ingress annotation already includes this certificate."
else
  NEW_CERT_ARNS="${CURRENT_CERT_ARNS:+${CURRENT_CERT_ARNS},}${ACM_CERT_ARN}"
  kubectl annotate ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
    "alb.ingress.kubernetes.io/certificate-arn=${NEW_CERT_ARNS}" --overwrite >/dev/null
  success "Ingress annotation updated: ${NEW_CERT_ARNS}"
fi

# =============================================================================
# 6. USERDATA (Java 21, Docker, CloudBees CI Client Controller as a systemd unit)
# =============================================================================
USERDATA_FILE="$(mktemp)"
trap 'rm -f "$USERDATA_FILE"' EXIT

cat > "$USERDATA_FILE" <<USERDATA
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "== Installing Java 21 =="
dnf update -y
dnf install -y java-21-amazon-corretto-headless unzip

echo "== Installing Docker =="
# AL2023 ships Docker directly in its own dnf repo — no extra repo/GPG setup
# needed (unlike Ubuntu's docker.com apt repo).
dnf install -y docker
systemctl enable --now docker

echo "== Preparing CloudBees CI Client Controller data volume =="
mkdir -p /var/lib/cloudbees-client-controller
chown -R 1000:1000 /var/lib/cloudbees-client-controller

echo "== Installing systemd unit for the Client Controller =="
cat > /etc/systemd/system/cloudbees-client-controller.service <<'UNIT'
[Unit]
Description=CloudBees CI Client Controller
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f cloudbees-client-controller
ExecStart=/usr/bin/docker run --rm --name cloudbees-client-controller \\
  -p ${EC2_CONTROLLER_PORT}:8080 \\
  -v /var/lib/cloudbees-client-controller:/var/jenkins_home \\
  -e JAVA_OPTS="-Xmx2g" \\
  ${CLOUDBEES_CONTROLLER_IMAGE}
ExecStop=/usr/bin/docker stop cloudbees-client-controller

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now cloudbees-client-controller.service

echo "== Bootstrap complete =="
USERDATA

# =============================================================================
# 7. LAUNCH (OR REUSE) THE EC2 INSTANCE
# =============================================================================
log "Checking for an existing instance named '${EC2_INSTANCE_NAME}'..."
INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  log "Resolving latest Amazon Linux 2023 AMI..."
  AMI_ID=$(aws ssm get-parameters --region "$AWS_REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text)
  success "AMI: ${AMI_ID}"

  RUN_ARGS=(
    --region "$AWS_REGION"
    --image-id "$AMI_ID"
    --instance-type "$EC2_INSTANCE_TYPE"
    --subnet-id "$SUBNET_ID"
    --security-group-ids "$EC2_SG_ID"
    --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE_NAME}"
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${EC2_VOLUME_SIZE_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
    --user-data "file://${USERDATA_FILE}"
    --tag-specifications "ResourceType=instance,Tags=[${TAG_SPEC}]"
    --metadata-options "HttpTokens=required"
  )
  [[ -n "$EC2_KEY_NAME" ]] && RUN_ARGS+=(--key-name "$EC2_KEY_NAME")

  log "Launching EC2 instance '${EC2_INSTANCE_NAME}'..."
  INSTANCE_ID=""
  for _ in $(seq 1 6); do
    if INSTANCE_ID=$(aws ec2 run-instances "${RUN_ARGS[@]}" \
      --query 'Instances[0].InstanceId' --output text 2>/tmp/run-instances.err); then
      break
    fi
    warn "run-instances failed (likely IAM instance profile still propagating), retrying in 10s..."
    cat /tmp/run-instances.err >&2 || true
    sleep 10
  done
  [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || error "failed to launch EC2 instance — see errors above"
  success "Instance launched: ${INSTANCE_ID}"

  log "Waiting for instance to reach 'running' state..."
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  success "Instance is running."
else
  success "Reusing existing instance: ${INSTANCE_ID}"
fi

# =============================================================================
# 8. TARGET GROUP + REGISTER TARGET + LISTENER RULE
# =============================================================================
log "Checking for existing target group '${TG_NAME}'..."
TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  log "Creating target group '${TG_NAME}' on port ${EC2_CONTROLLER_PORT}..."
  TG_ARN=$(aws elbv2 create-target-group --region "$AWS_REGION" \
    --name "$TG_NAME" --protocol HTTP --port "$EC2_CONTROLLER_PORT" --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP --health-check-path /login --health-check-port traffic-port \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  aws elbv2 add-tags --region "$AWS_REGION" --resource-arns "$TG_ARN" \
    --tags Key=cb-user,Value="$TAG_CB_USER" Key=cb-owner,Value="$TAG_CB_OWNER" Key=cb-environment,Value="$TAG_CB_ENVIRONMENT" >/dev/null
  success "Target group created: ${TG_ARN}"
else
  success "Target group already exists: ${TG_ARN}"
fi

log "Registering instance ${INSTANCE_ID} with target group..."
aws elbv2 register-targets --region "$AWS_REGION" --target-group-arn "$TG_ARN" \
  --targets "Id=${INSTANCE_ID},Port=${EC2_CONTROLLER_PORT}" >/dev/null
success "Target registered."

log "Checking for an existing listener rule for host '${EC2_HOST_NAME}'..."
EXISTING_RULE_ARN=$(aws elbv2 describe-rules --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Conditions[?Field=='host-header' && contains(Values, '${EC2_HOST_NAME}')]].RuleArn | [0]" --output text 2>/dev/null || true)

if [[ -z "$EXISTING_RULE_ARN" || "$EXISTING_RULE_ARN" == "None" ]]; then
  USED_PRIORITIES=$(aws elbv2 describe-rules --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Priority!='default'].Priority" --output text)
  NEXT_PRIORITY=1
  for p in $USED_PRIORITIES; do
    (( p >= NEXT_PRIORITY )) && NEXT_PRIORITY=$((p + 1))
  done

  log "Creating listener rule (priority ${NEXT_PRIORITY}) forwarding host '${EC2_HOST_NAME}' -> target group..."
  aws elbv2 create-rule --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
    --priority "$NEXT_PRIORITY" \
    --conditions "Field=host-header,Values=${EC2_HOST_NAME}" \
    --actions "Type=forward,TargetGroupArn=${TG_ARN}" >/dev/null
  success "Listener rule created."
else
  success "Listener rule already exists: ${EXISTING_RULE_ARN}"
fi

# =============================================================================
# 9. ROUTE53 ALIAS A RECORD
# =============================================================================
log "Resolving hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE_DOMAIN}." \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
  --output text | sed 's#/hostedzone/##')
[[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]] \
  || error "no public hosted zone for '${ROUTE53_ZONE_DOMAIN}' — create it, or set ROUTE53_ZONE_DOMAIN in .env"

log "Upserting alias A record ${EC2_HOST_NAME} -> ${ALB_DNS}..."
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${EC2_HOST_NAME}\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"${ALB_CANONICAL_ZONE_ID}\",
          \"DNSName\": \"${ALB_DNS}\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }" >/dev/null
success "Route53 alias record upserted."

# =============================================================================
# SUMMARY
# =============================================================================
echo
success "Done. Summary:"
echo "  Instance ID         : ${INSTANCE_ID}"
echo "  VPC / Subnet        : ${VPC_ID} / ${SUBNET_ID}"
echo "  Security Group      : ${EC2_SG_ID}"
echo "  Cluster Security Grp : ${CLUSTER_SG_ID} (443 allowed from ${SG_NAME})"
echo "  IAM Instance Profile : ${IAM_INSTANCE_PROFILE_NAME}"
echo "  Target Group        : ${TG_ARN}"
echo "  ACM Certificate     : ${ACM_CERT_ARN}"
echo "  Shared ALB          : ${ALB_DNS}"
echo
echo "URL: https://${EC2_HOST_NAME}/"
echo
echo "Verify EKS API reachability from the instance (e.g. via SSM Session Manager):"
echo "  curl -k \$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.endpoint' --output text)/version"
echo
warn "Reminder: the container is up and reachable, but it is NOT yet attached to"
warn "the existing Operations Center as a managed Client Controller — complete"
warn "that association from CJOC's 'Add Controller' UI (or CasC), and confirm"
warn "CLOUDBEES_CONTROLLER_IMAGE in .env matches your licensed CloudBees CI version."
