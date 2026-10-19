# =============================================================================
# IRSA ROLES — replaces `iam.serviceAccounts` + addon `wellKnownPolicies`
# =============================================================================
locals {
  oidc_host = replace(aws_iam_openid_connect_provider.this.url, "https://", "")

  # role key => { service_account, policy_arns }
  # eksctl's wellKnownPolicies were shorthand for exactly these AWS managed
  # policies; naming them explicitly makes the grant auditable in a plan.
  irsa_roles = {
    ebs_csi = {
      service_account = "kube-system:ebs-csi-controller-sa"
      policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
    efs_csi = {
      service_account = "kube-system:efs-csi-controller-sa"
      policy_arns     = ["arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"]
    }
    alb_controller = {
      service_account = "kube-system:aws-load-balancer-controller"
      policy_arns     = [aws_iam_policy.alb_controller.arn]
    }
    cluster_autoscaler = {
      service_account = "kube-system:cluster-autoscaler"
      policy_arns     = [aws_iam_policy.cluster_autoscaler.arn]
    }
  }

  # Flattened role/policy pairs so a single for_each can attach all of them.
  irsa_attachments = merge([
    for key, cfg in local.irsa_roles : {
      for arn in cfg.policy_arns : "${key}:${arn}" => { role = key, policy_arn = arn }
    }
  ]...)
}

data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = local.irsa_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # Both conditions are required. Without the :sub check any service account
    # in the cluster could assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      # service_account is already "namespace:name".
      values = ["system:serviceaccount:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_roles

  name               = "${var.cluster_name}-${replace(each.key, "_", "-")}-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[each.key].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = local.irsa_attachments

  role       = aws_iam_role.irsa[each.value.role].name
  policy_arn = each.value.policy_arn
}

# --- AWS Load Balancer Controller policy -------------------------------------
# Sourced from the upstream project's iam_policy.json. Refresh it when the
# controller is upgraded — new controller versions periodically require new
# actions, and the failure mode is an AccessDenied buried in controller logs:
#   curl -o policies/aws-load-balancer-controller.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  description = "Permissions for the AWS Load Balancer Controller on ${var.cluster_name}"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")
  tags        = local.tags
}

# --- Cluster Autoscaler policy ------------------------------------------------
# Equivalent of eksctl's `wellKnownPolicies.autoScaler`: read access to describe
# ASGs/launch templates plus the two mutating actions the autoscaler actually
# needs (resize a group, terminate a specific instance within it). Not
# resource-scoped to particular ASG ARNs — cluster-autoscaler discovers node
# groups to manage at runtime via the k8s.io/cluster-autoscaler/* tags EKS
# stamps on each managed node group's ASG, so it cannot be known upfront which
# ASG ARNs to scope to.
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.cluster_name}-ClusterAutoscalerIAMPolicy"
  description = "Permissions for the Kubernetes Cluster Autoscaler on ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
  tags        = local.tags
}

# =============================================================================
# EKS POD IDENTITY — external-dns
# =============================================================================
# external-dns uses Pod Identity rather than IRSA (matching the original
# eksctl config), so there is no OIDC trust-policy plumbing — the Pod Identity
# Agent addon delivers credentials to the pod at runtime.
data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json
  tags               = local.tags
}

# Least privilege: writes are scoped to the one hosted zone we own. The List*
# actions cannot be resource-scoped by Route53, hence the "*".
data "aws_iam_policy_document" "external_dns" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.this.zone_id}"]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns-route53"
  description = "Route53 writes scoped to ${local.zone_domain} for external-dns"
  policy      = data.aws_iam_policy_document.external_dns.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
  tags            = local.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}
