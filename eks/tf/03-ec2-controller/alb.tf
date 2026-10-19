# =============================================================================
# RESOLVE THE EXISTING SHARED ALB — replaces step 2 of
# 07-createEC2WithController.sh
# =============================================================================
# The bash version resolved the ALB by reading the cjoc-alb Ingress status
# with kubectl, then matching its DNS name against `aws elbv2
# describe-load-balancers`. This module has no kubernetes/kubectl provider
# (see providers.tf), so it matches the same load balancer a different way:
# by the tags the AWS Load Balancer Controller stamps onto every ALB it
# provisions from an Ingress (`ingress.k8s.aws/stack = <namespace>/<name>`).
# That tagging behaviour is documented upstream and has been stable across
# controller versions.
data "aws_vpc" "this" {
  id = local.infra.vpc_id
}

data "aws_lbs" "shared_candidates" {
  tags = {
    "ingress.k8s.aws/stack" = "${var.envoy_gw_namespace}/${var.ingress_name}"
  }
}

data "aws_lb" "shared" {
  arn = tolist(data.aws_lbs.shared_candidates.arns)[0]
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

# =============================================================================
# TARGET GROUP + LISTENER RULE — replaces step 8 of the script
# =============================================================================
resource "aws_lb_target_group" "this" {
  name        = "${local.instance_name}-tg"
  port        = var.controller_port
  protocol    = "HTTP"
  vpc_id      = local.infra.vpc_id
  target_type = "instance"

  health_check {
    protocol = "HTTP"
    path     = "/login"
    port     = "traffic-port"
  }

  tags = local.tags
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.this.id
  port             = var.controller_port
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = [var.ec2_controller_host_name]
    }
  }

  tags = local.tags
}
