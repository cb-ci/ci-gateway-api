apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

# =============================================================================
# CLUSTER BASICS
# =============================================================================
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "1.35"
  # Applied to the CloudFormation-managed resources eksctl creates for the
  # cluster itself: the EKS cluster resource, VPC, subnets, route tables,
  # NAT gateway, and security groups. Does NOT automatically propagate to
  # managed node groups, addons, or IAM roles/service accounts — each of
  # those has its own `tags` block below, set to the same values, so that
  # literally every resource in this file carries the required tags.
  tags: &common-tags
    cb-user: ${TAG_CB_USER}
    cb-owner: ${TAG_CB_OWNER}
    cb-environment: ${TAG_CB_ENVIRONMENT}

# -----------------------------------------------------------------------------
# NOTE on Availability Zones:
# AWS EKS requires the control plane's cross-account ENIs to span AT LEAST
# 2 distinct AZs — this is a hard AWS-side requirement, not an eksctl
# limitation, and cannot be relaxed even for a "single-AZ" design.
#
# This config lets eksctl create and manage a brand-new, dedicated VPC
# (no existing VPC is referenced anywhere here). For that case, explicit
# per-subnet CIDRs under `vpc.subnets` are NOT the right tool — that field
# is only for importing/validating subnets in an EXISTING VPC (it requires
# `vpc.id` and looks subnets up by ID/CIDR against that VPC). Instead, the
# standard way to control layout for a NEW VPC is:
#   - `vpc.cidr` below sets the overall VPC range.
#   - the top-level `availabilityZones` field tells eksctl which AZs to
#     auto-partition that range across when generating public/private
#     subnets — here, us-east-1a and us-east-1b (the AWS-required minimum
#     for the control plane).
#   - Each managed node group's own `availabilityZones` field (further
#     below) then pins ALL worker nodes to us-east-1a only. No compute
#     ever lands in us-east-1b; that AZ exists solely to satisfy the
#     control-plane requirement above.
# -----------------------------------------------------------------------------
availabilityZones:
  - us-east-1a
  - us-east-1b

# =============================================================================
# NETWORK SETUP
# =============================================================================
vpc:
  cidr: "10.0.0.0/16" # overall VPC range; eksctl auto-derives public/private
  # subnets from this across the AZs listed in top-level `availabilityZones`

  # Fully private worker-node networking: nodes only ever get private IPs
  # and route out through NAT — no public IPs, no direct internet ingress.
  nat:
    gateway: Single # one NAT GW (in the public subnet) for private subnet egress (image pulls, etc.)

  clusterEndpoints:
    publicAccess: true # kubectl / CI/CD pipelines reach the API server over the internet
    privateAccess: true # nodes/pods reach the API server via the VPC-private endpoint (required for private-subnet nodes)

# =============================================================================
# IAM (cluster-level) — required for IRSA used by add-ons/service accounts below
# =============================================================================
# aws-load-balancer-controller:
#   Reconciles Kubernetes Ingress/Service objects into AWS Application Load
#   Balancers (ALBs). In this setup it provisions a PUBLIC-facing ALB that
#   sits in the public subnets and forwards traffic into the cluster's
#   PRIVATE subnets — this is what exposes Envoy Gateway (or any Gateway
#   API / Ingress) to the internet without ever giving worker nodes public
#   IPs. Typical flow for CloudBees CI:
#     Internet -> public ALB -> Envoy Gateway (Gateway API) -> CI controller/agent Services
#
# external-dns:
#   Watches Ingress/Gateway/Service objects and automatically creates/updates
#   Route53 records (e.g. ci.example.com -> ALB DNS name) so the public ALB
#   above gets a stable, human-friendly hostname without manual DNS upkeep.
#   Scoped here via a custom least-privilege Route53 policy rather than full
#   Route53 admin access.
#
# cluster-autoscaler:
#   Adjusts each managed node group between its minSize/maxSize based on
#   pending-pod pressure and node utilization. eksctl auto-tags a node
#   group's ASG for auto-discovery (k8s.io/cluster-autoscaler/<cluster>,
#   k8s.io/cluster-autoscaler/enabled) whenever minSize != maxSize, which is
#   already true for both pools below — this SA only grants the IAM
#   permissions; the controller itself is installed separately by
#   03-installClusterAutoscaler.sh.
# =============================================================================
iam:
  withOIDC: true # still needed: aws-load-balancer-controller below uses IRSA
  serviceAccounts:
    - metadata:
        name: aws-load-balancer-controller
        namespace: kube-system
      wellKnownPolicies:
        awsLoadBalancerController: true
      tags: *common-tags

    - metadata:
        name: cluster-autoscaler
        namespace: kube-system
      wellKnownPolicies:
        autoScaler: true
      tags: *common-tags

  # external-dns uses EKS Pod Identity instead of IRSA — no OIDC provider
  # trust-policy plumbing needed; the Pod Identity Agent add-on (declared
  # above) handles credential delivery to the pod at runtime.
  # `wellKnownPolicies.externalDNS: true` is eksctl's built-in, least-
  # privilege Route53 policy (ChangeResourceRecordSets scoped to hosted
  # zones + read-only List* actions) — equivalent to the custom policy
  # used previously, but maintained by eksctl.
  podIdentityAssociations:
    - namespace: kube-system
      serviceAccountName: external-dns
      createServiceAccount: true # eksctl creates the k8s ServiceAccount if it doesn't exist
      wellKnownPolicies:
        externalDNS: true
      tags: *common-tags

# =============================================================================
# NODE POOLS (Managed Node Groups)
# =============================================================================
managedNodeGroups:

  # ---------------------------------------------------------------------------
  # Pool 1: controllers
  # Dedicated, tainted pool for CloudBees CI "controller" pods so that only
  # controller workloads are scheduled here (kept off shared agent capacity).
  # Graviton (ARM64) instances for better price/performance on control-plane
  # style, steady-state workloads.
  # ---------------------------------------------------------------------------
  - name: controllers
    privateNetworking: true # nodes get ENIs only in private subnets
    availabilityZones:
      - us-east-1a # pinned to the single target AZ
    instanceTypes:
      - m7g.xlarge # ARM64 / Graviton3
      - m7g.2xlarge # ARM64 / Graviton3
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    volumeSize: 80
    labels:
      workload: controller
    taints:
      - key: workload
        value: controller
        effect: NoSchedule
    tags:
      <<: *common-tags
      role: cloudbees-ci-controllers

  # ---------------------------------------------------------------------------
  # Pool 2: agents
  # x86_64 pool for CloudBees CI build agents. Tainted (mirroring the
  # controllers pool) so nothing schedules here without an explicit
  # toleration for `workload=agent` — strict isolation in both directions.
  # Default AWS-managed DaemonSets (aws-node, kube-proxy, EBS/EFS CSI node
  # plugins) already tolerate all NoSchedule taints, so this is safe.
  # ---------------------------------------------------------------------------
  - name: agents
    privateNetworking: true
    availabilityZones:
      - us-east-1a
    instanceTypes:
      - m6i.xlarge # x86_64
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    volumeSize: 100
    labels:
      workload: agent
    taints:
      - key: workload
        value: agent
        effect: NoSchedule
    tags:
      <<: *common-tags
      role: cloudbees-ci-agents

  # ---------------------------------------------------------------------------
  # Pool 3: system
  # Deliberately untainted. Once `controllers` and `agents` were both
  # tainted (above), every cluster-system Deployment without a matching
  # toleration — CoreDNS, EBS/EFS CSI controllers, Envoy Gateway,
  # external-dns, aws-load-balancer-controller, cluster-autoscaler,
  # metrics-server — had nowhere left to schedule at all. Rather than patch
  # tolerations onto each one individually (fragile: different tool per
  # component — EKS addon configurationValues, Helm values, raw manifests —
  # and easy to miss one, or regress it later), this pool exists purely so
  # cluster add-ons always have somewhere to run with zero changes to their
  # own specs. Small and cheap on purpose: it only needs to hold lightweight
  # control-plane-adjacent Deployments, not CI workloads.
  # ---------------------------------------------------------------------------
  - name: system
    privateNetworking: true
    availabilityZones:
      - us-east-1a
    instanceTypes:
      - m6i.large # x86_64, small — control-plane-adjacent pods only
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    volumeSize: 60
    labels:
      workload: system
    tags:
      <<: *common-tags
      role: cloudbees-ci-system

# =============================================================================
# MANAGED ADD-ONS
# =============================================================================
# aws-ebs-csi-driver: provides ReadWriteOnce block storage (PVCs) for stateful
#   CloudBees CI controller pods (Jenkins home / JENKINS_HOME-style volumes).
# aws-efs-csi-driver: provides ReadWriteMany shared storage, useful for shared
#   CI artifact caches / shared workspaces across multiple agent pods.
# Both use `wellKnownPolicies` so eksctl auto-creates the IRSA role + IAM
# policy + trust relationship — no manual IAM authoring needed.
# =============================================================================
addons:
  # Both CSI driver *controller* Deployments (the external-attacher/
  # provisioner sidecars) don't tolerate custom taints by default — only the
  # per-node DaemonSet does. Now that both `controllers` and `agents` are
  # tainted, there is no untainted node left for the controller Deployment to
  # land on, so it must be given an explicit toleration or every PVC attach/
  # provision request times out with no attacher available to service it.
  # Verified against `aws eks describe-addon-configuration` for
  # aws-ebs-csi-driver: `tolerations` lives under `controller`, and the
  # schema's `additionalProperties: false` means a top-level key is rejected
  # outright. The two entries below (CriticalAddonsOnly, NoExecute) are the
  # addon's own defaults, restated here because configurationValues replaces
  # the whole `tolerations` list rather than appending to it.
  - name: aws-ebs-csi-driver
    # `wellKnownPolicies` directly on the addon (no longer used here — see
    # below) is what originally caused eksctl to auto-create a pod identity
    # association for this addon at cluster-creation time. Once that
    # association exists live, `eksctl update addon` refuses to touch the
    # addon unless it's restated in config. This eksctl version (0.229.0)
    # rejects a manually-specified `podIdentityAssociations` array with
    # `wellKnownPolicies` inside it — the supported mechanism is
    # `useDefaultPodIdentityAssociations`, which tells eksctl to derive and
    # keep reconciling the addon's own recommended IAM policy + association
    # automatically. (A prior version of this file used an explicit
    # `podIdentityAssociations` block with `roleARN` pointing at the
    # existing eksctl-managed role, which told eksctl to stop managing that
    # role's policy — the next update then detached
    # AmazonEBSCSIDriverPolicy from it, breaking
    # ec2:DescribeAvailabilityZones and everything else the driver needs.)
    useDefaultPodIdentityAssociations: true
    configurationValues: |
      controller:
        tolerations:
          - key: CriticalAddonsOnly
            operator: Exists
          - effect: NoExecute
            operator: Exists
            tolerationSeconds: 300
          - key: workload
            operator: Exists
            effect: NoSchedule
    tags: *common-tags

  # NOT yet verified against this addon's own configurationSchema — its
  # chart may not share aws-ebs-csi-driver's exact shape. Run
  # `aws eks describe-addon-configuration --addon-name aws-efs-csi-driver`
  # and confirm the `controller.tolerations` path before relying on this.
  - name: aws-efs-csi-driver
    wellKnownPolicies:
      efsCSIController: true
    configurationValues: |
      controller:
        tolerations:
          - key: CriticalAddonsOnly
            operator: Exists
          - effect: NoExecute
            operator: Exists
            tolerationSeconds: 300
          - key: workload
            operator: Exists
            effect: NoSchedule
    tags: *common-tags

  - name: eks-pod-identity-agent
    # ^ required: runs the Pod Identity Agent DaemonSet that external-dns's
    # podIdentityAssociation (under iam.podIdentityAssociations, below) depends on
    tags: *common-tags