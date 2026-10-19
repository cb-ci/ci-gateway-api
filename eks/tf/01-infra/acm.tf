# =============================================================================
# ACM CERTIFICATE + DNS VALIDATION
# =============================================================================
# Replaces the request/poll/upsert-CNAME/wait block in 04-installEnvoy.sh.
# Terraform models the whole dance declaratively, so there is no polling loop,
# no `sleep`, and no risk of reusing a stale PENDING_VALIDATION certificate:
# aws_acm_certificate_validation blocks until the cert is actually ISSUED.

data "aws_route53_zone" "this" {
  name         = "${local.zone_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "cjoc" {
  domain_name       = var.cjoc_host_name
  validation_method = "DNS"

  tags = merge(local.tags, { Name = "${var.cjoc_host_name}-acm-cert" })

  # ACM issues a replacement before the old cert is detached from the ALB.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cjoc_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cjoc.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cjoc" {
  certificate_arn         = aws_acm_certificate.cjoc.arn
  validation_record_fqdns = [for r in aws_route53_record.cjoc_validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}
