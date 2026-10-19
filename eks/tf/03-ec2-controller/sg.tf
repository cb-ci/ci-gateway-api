# =============================================================================
# SECURITY GROUP — replaces step 3 of 07-createEC2WithController.sh
# =============================================================================
resource "aws_security_group" "this" {
  name        = "${local.instance_name}-sg"
  description = "CloudBees CI Client Controller EC2 instance (${var.ec2_controller_host_name})"
  vpc_id      = local.infra.vpc_id

  tags = merge(local.tags, { Name = "${local.instance_name}-sg" })
}

# Mirrors the original script, which opened 80/443 in addition to
# controller_port even though the target group only ever forwards to
# controller_port. Outbound: the default SG egress AWS creates automatically
# already allows all traffic — nothing to add here (same as efs.tf).
resource "aws_vpc_security_group_ingress_rule" "from_alb_controller_port" {
  security_group_id            = aws_security_group.this.id
  description                  = "Client Controller port from the shared ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.controller_port
  to_port                      = var.controller_port
  referenced_security_group_id = data.aws_lb.shared.security_groups[0]
}

resource "aws_vpc_security_group_ingress_rule" "from_alb_http" {
  security_group_id            = aws_security_group.this.id
  description                  = "HTTP from the shared ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = data.aws_lb.shared.security_groups[0]
}

resource "aws_vpc_security_group_ingress_rule" "from_alb_https" {
  security_group_id            = aws_security_group.this.id
  description                  = "HTTPS from the shared ALB"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = data.aws_lb.shared.security_groups[0]
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.this.id
  description       = "SSH (fallback — SSM Session Manager works without it)"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = local.ssh_cidr
}

# =============================================================================
# EKS API ACCESS — lets this instance reach the Kubernetes API server (443)
# =============================================================================
# Not needed for the Client Controller container itself (it only talks to
# CJOC, never the K8s API), but the instance sits inside the VPC and
# 01-infra enables endpoint_private_access, so any client here resolves the
# cluster endpoint to a private ENI IP rather than the public one — gated by
# the EKS-managed cluster security group, not by internet routing. Without
# this rule, `kubectl`/`curl` from this instance times out even though
# outbound internet access (via the NAT gateway) works fine for everything
# else. This modifies the *cluster's* security group, not this instance's own.
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_this" {
  security_group_id            = local.infra.cluster_security_group_id
  description                  = "EKS API (443) from ${local.instance_name}"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.this.id
}

