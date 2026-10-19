# =============================================================================
# ROUTE53 ALIAS RECORD — replaces step 9 of 07-createEC2WithController.sh
# =============================================================================
# An alias A record, not a CNAME, and pointed at the shared ALB directly —
# same mechanism external-dns uses for cjoc_host_name in 02-platform, just
# declared here instead of reconciled by a controller (external-dns's
# `source: ingress` never sees this record; there is no Ingress for it).
resource "aws_route53_record" "this" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.ec2_controller_host_name
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}
