#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# _cleanup-lib.sh — Shared cleanup helpers for the delete scripts. Sourced, not
# run. Expects the caller to define log/success/warn and AWS_REGION, and .env
# (CLUSTER_NAME) to be loaded.
#
#   Route53 ACM validation CNAMEs   list_/delete_acm_validation_cnames <host>
#     Deleting an ACM certificate does NOT remove its DNS-validation CNAME.
#     Only `_<hex>.<host>.` CNAMEs pointing at *.acm-validations.aws. are touched,
#     and only while no ACM certificate for <host> exists.
#
#   Leftover ACM certificates       list_/delete_leftover_acm_certs <host>
#     Only certificates for exactly <host> that no resource uses (InUseBy empty)
#     and that carry the tag cb-user=${TAG_CB_USER} (set by the install scripts).
#
#   Leftover Route53 records        list_/delete_leftover_dns_records <host>
#     Exact names only: the host's A/AAAA alias when no load balancer with that
#     DNS name exists any more, and the external-dns TXT registry records
#     (<host>, a-<host>, cname-<host>) whose value names THIS cluster's owner id
#     (TXT_OWNER_ID, default CLUSTER_NAME). Other owners' records are never touched.
#
#   LB controller security groups   list_/delete_lb_security_groups
#     The AWS Load Balancer Controller creates security groups (k8s-traffic-...)
#     outside the eksctl stacks. A leftover one blocks VPC deletion and hangs
#     `eksctl delete cluster`. Only groups inside THIS cluster's VPC that carry the
#     tag elbv2.k8s.aws/cluster=<cluster> or are named k8s-traffic-<cluster>-*
#     are touched. Deletion fails harmlessly while an ENI or rule still uses one.
# -----------------------------------------------------------------------------

# Prints one compact JSON object {zone, rr} per line; empty while a certificate for the host exists.
list_acm_validation_cnames() {
  local host="$1" n zone_id
  n=$(aws acm list-certificates --region "$AWS_REGION" \
        --query "length(CertificateSummaryList[?DomainName=='${host}'])" --output text 2>/dev/null || echo 0)
  [[ "$n" == "0" || "$n" == "None" ]] || return 0
  zone_id=$(host_zone_id "$host")
  [[ -n "$zone_id" ]] || return 0
  aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null \
    | jq -c --arg h "$host" --arg z "$zone_id" '.ResourceRecordSets[]
        | select(.Type == "CNAME")
        | select(.Name | test("^_[0-9a-f]+\\.") and endswith("." + $h + "."))
        | select(.ResourceRecords[0].Value | endswith(".acm-validations.aws."))
        | {zone: $z, rr: .}' || true
}

# Public hosted zone id for HOST's parent domain (override: ROUTE53_ZONE_DOMAIN).
host_zone_id() {
  local zone_domain zone_id
  zone_domain="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$1")}"
  zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$zone_domain" \
    --query "HostedZones[?Name=='${zone_domain}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>/dev/null | sed 's|/hostedzone/||' || true)
  [[ -n "$zone_id" && "$zone_id" != "None" ]] && echo "$zone_id"
  return 0
}

# Reads {zone, rr} lines on stdin and deletes each record set.
delete_route53_items() {
  local item name zone
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name=$(jq -r '.rr.Name' <<< "$item")
    zone=$(jq -r '.zone' <<< "$item")
    log "Deleting Route53 record $(jq -r '.rr.Type' <<< "$item") ${name}..."
    aws route53 change-resource-record-sets --hosted-zone-id "$zone" \
      --change-batch "$(jq -c '{Changes:[{Action:"DELETE",ResourceRecordSet:.rr}]}' <<< "$item")" >/dev/null \
      && success "Record removed." \
      || warn "Could not delete ${name}; remove it manually in Route53."
  done
}

delete_acm_validation_cnames() {
  delete_route53_items < <(list_acm_validation_cnames "$1")
}

# Prints the ARNs of unused, tag-matching certificates for exactly HOST.
list_leftover_acm_certs() {
  local host="$1" arn in_use tag
  for arn in $(aws acm list-certificates --region "$AWS_REGION" \
      --query "CertificateSummaryList[?DomainName=='${host}'].CertificateArn" --output text 2>/dev/null || true); do
    in_use=$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$arn" \
      --query 'length(Certificate.InUseBy)' --output text 2>/dev/null || echo 1)
    [[ "$in_use" == "0" ]] || continue
    tag=$(aws acm list-tags-for-certificate --region "$AWS_REGION" --certificate-arn "$arn" \
      --query "Tags[?Key=='cb-user'].Value | [0]" --output text 2>/dev/null || true)
    [[ -n "${TAG_CB_USER:-}" && "$tag" == "$TAG_CB_USER" ]] && echo "$arn"
  done
  return 0
}

delete_leftover_acm_certs() {
  local host="$1" arn
  for arn in $(list_leftover_acm_certs "$host"); do
    log "Deleting unused ACM certificate ${arn} (${host})..."
    aws acm delete-certificate --region "$AWS_REGION" --certificate-arn "$arn" \
      && success "Certificate deleted." \
      || warn "Could not delete ${arn}."
  done
}

# Prints {zone, rr} lines for HOST's leftover alias and external-dns registry records.
list_leftover_dns_records() {
  local host="$1" zone_id albs
  zone_id=$(host_zone_id "$host")
  [[ -n "$zone_id" ]] || return 0
  albs=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].DNSName' --output json 2>/dev/null \
    | jq -c 'map(ascii_downcase)' 2>/dev/null || echo '[]')
  aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null \
    | jq -c --arg h "$host" --arg z "$zone_id" --arg o "${TXT_OWNER_ID:-${CLUSTER_NAME}}" --argjson albs "${albs:-[]}" '
        .ResourceRecordSets[]
        | select(
            ((.Type == "A" or .Type == "AAAA") and .Name == ($h + ".") and (.AliasTarget != null)
              and ((.AliasTarget.DNSName | ascii_downcase | sub("^dualstack\\."; "") | sub("\\.$"; "")) as $d
                   | ($albs | index($d)) == null))
            or
            (.Type == "TXT" and (.Name == ($h + ".") or .Name == ("a-" + $h + ".") or .Name == ("cname-" + $h + "."))
              and ((.ResourceRecords // []) | map(.Value) | join(" ") | contains("external-dns/owner=" + $o + ",")))
          )
        | {zone: $z, rr: .}' || true
}

delete_leftover_dns_records() {
  delete_route53_items < <(list_leftover_dns_records "$1")
}

# VPC id by eksctl tag; works after the EKS cluster is gone, as long as the VPC exists.
find_cluster_vpc() {
  local vpc
  vpc=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
  [[ -n "$vpc" && "$vpc" != "None" ]] && echo "$vpc"
  return 0
}

# Prints the ids of the cluster's LB controller security groups, one per line.
list_lb_security_groups() {
  local vpc
  vpc=$(find_cluster_vpc)
  [[ -n "$vpc" ]] || return 0
  {
    aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${vpc}" "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true
    aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=k8s-traffic-${CLUSTER_NAME}-*" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true
  } | tr '\t' '\n' | sort -u | grep -v '^$' || true
}

# One pass. Returns 0 when none remain, 1 when some are still in use.
delete_lb_security_groups() {
  local sg left=0
  for sg in $(list_lb_security_groups); do
    if aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" >/dev/null 2>&1; then
      log "Deleted leftover LB controller security group ${sg}."
    else
      left=1
    fi
  done
  return $left
}

# Retries delete_lb_security_groups until none remain or the time limit (seconds) passes.
wait_delete_lb_security_groups() {
  local limit="${1:-120}" waited=0
  while ! delete_lb_security_groups; do
    (( waited >= limit )) && return 1
    sleep 10; waited=$((waited + 10))
  done
}
