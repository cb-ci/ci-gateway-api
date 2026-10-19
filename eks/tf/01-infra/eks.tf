# =============================================================================
# EKS CONTROL PLANE + NODE GROUPS — replaces eksctl-config.yaml
# =============================================================================
# Native provider resources rather than terraform-aws-modules/eks: the module's
# input names have churned across major versions, while these resource schemas
# have been stable for years. More lines, fewer surprises on upgrade.

# --- Cluster IAM role ---------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Control plane ------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)

    # Mirrors clusterEndpoints in eksctl-config.yaml: kubectl reaches the API
    # over the internet, nodes in private subnets reach it over the VPC.
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --- IRSA OIDC provider -------------------------------------------------------
# Equivalent of eksctl's `iam.withOIDC: true`. Required by the EBS CSI, EFS CSI
# and AWS Load Balancer Controller service accounts below.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = local.tags
}

# --- Node IAM role ------------------------------------------------------------
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Required for the EKS Pod Identity Agent to hand credentials to pods.
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Only the private subnet in node_az — every node group pins compute to that
# single AZ, matching each managed node group's `availabilityZones` in eksctl.
locals {
  node_subnet_ids = [
    for idx, az in var.azs : module.vpc.private_subnets[idx] if az == var.node_az
  ]
}

# --- Pool 1: controllers (tainted, ARM64/Graviton) ---------------------------
resource "aws_eks_node_group" "controllers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "controllers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.node_subnet_ids

  instance_types = var.controller_instance_types
  ami_type       = "AL2023_ARM_64_STANDARD"
  disk_size      = 80

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  labels = {
    workload = "controller"
  }

  # Keeps CI workloads off the controller pool. Cluster add-ons that don't
  # carry a workload-specific toleration schedule onto the untainted
  # "system" pool below, not here or on "agents".
  taint {
    key    = "workload"
    value  = "controller"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.tags, { role = "cloudbees-ci-controllers" })

  lifecycle {
    # desired_size drifts as the cluster autoscales; do not fight it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --- Pool 2: agents (tainted, x86_64) ----------------------------------------
resource "aws_eks_node_group" "agents" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "agents"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.node_subnet_ids

  instance_types = var.agent_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = 100

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  labels = {
    workload = "agent"
  }

  # Mirrors the "controllers" taint above so nothing schedules here without
  # an explicit toleration for workload=agent — strict isolation in both
  # directions. Default AWS-managed DaemonSets (aws-node, kube-proxy,
  # EBS/EFS CSI node plugins) already tolerate all NoSchedule taints, so
  # this is safe.
  taint {
    key    = "workload"
    value  = "agent"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.tags, { role = "cloudbees-ci-agents" })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --- Pool 3: system (untainted, x86_64) --------------------------------------
# Deliberately untainted. Once "controllers" and "agents" were both tainted
# (above), every cluster-system Deployment without a matching toleration —
# CoreDNS, EBS/EFS CSI controllers, Envoy Gateway, external-dns,
# aws-load-balancer-controller, cluster-autoscaler, metrics-server — had
# nowhere left to schedule at all. This pool exists purely so cluster
# add-ons always have somewhere to run with zero changes to their own
# specs. Small and cheap on purpose: it only needs to hold lightweight
# control-plane-adjacent Deployments, not CI workloads.
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.node_subnet_ids

  instance_types = var.system_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = 60

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  labels = {
    workload = "system"
  }

  tags = merge(local.tags, { role = "cloudbees-ci-system" })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
