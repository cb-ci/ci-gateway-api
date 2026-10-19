# =============================================================================
# ACM CERTIFICATE (SNI) — replaces step 5 of 07-createEC2WithController.sh
# =============================================================================
# Same declarative pattern as 01-infra/acm.tf: aws_acm_certificate_validation
# blocks until the certificate is actually ISSUED, so there is no polling loop
# and no risk of attaching a stale PENDING_VALIDATION certificate. This
# certificate is added to the shared listener via SNI (aws_lb_listener_certificate)
# — it does not replace the listener's default certificate from 01-infra.
data "aws_route53_zone" "this" {
  name         = "${local.zone_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  domain_name       = var.ec2_controller_host_name
  validation_method = "DNS"

  tags = merge(local.tags, { Name = "${var.ec2_controller_host_name}-acm-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}

# Attaches as an additional (SNI) certificate — never touches the listener's
# default certificate, which 01-infra/02-platform own.
resource "aws_lb_listener_certificate" "this" {
  listener_arn    = data.aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn
}
