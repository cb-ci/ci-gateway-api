# Terraform: CloudBees CI on EKS

Provisions a demo CloudBees CI environment on Amazon EKS: a cluster with
dedicated controller/agent/system node pools, a shared Application Load
Balancer fronting an in-cluster Operations Center (CJOC) and an optional
standalone EC2-hosted Client Controller, TLS via ACM, and DNS via Route53.

## Layout

Three root modules, applied in order:

| | Creates |
| --- | --- |
| `01-infra/` | VPC, EKS cluster, 3 node groups, addons, IRSA + Pod Identity roles (incl. cluster-autoscaler), EFS, ACM certificate |
| `02-platform/` | AWS Load Balancer Controller, Cluster Autoscaler, Envoy Gateway, Gateway API resources, ALB Ingress, StorageClass, CloudBees CI, external-dns, jenkins-agent ServiceAccount/RBAC/token for the remote Kubernetes Cloud |
| `03-ec2-controller/` *(optional)* | Standalone EC2 Client Controller: security group, IAM role/instance profile, ACM cert (SNI), EC2 instance, target group + host-header listener rule on the shared ALB, Route53 alias record, cluster-security-group rule for API access |

`03-ec2-controller` is entirely optional — skip it if you don't need a
second, EC2-hosted Client Controller alongside the in-cluster CJOC. See
[Standalone EC2 Client Controller](#standalone-ec2-client-controller-03-ec2-controller)
below for what it creates and how it finds the shared ALB.

`terraform destroy` covers teardown for all three modules. Two things worth
knowing:

- `terraform destroy` on `02-platform` deletes the StorageClass, and the EFS
  `reclaimPolicy: Delete` takes the PVC data with it. Back up or change the
  reclaim policy first if you want volumes to survive.
- `terraform destroy` on `03-ec2-controller` always deletes its ACM
  certificate, since Terraform owns it as a normal resource — there is no
  option to retain it.

### Why two modules and not one

The `kubernetes`, `helm` and `kubectl` providers need the cluster endpoint and
CA to configure themselves. If those came from resources in the same apply,
Terraform would be configuring a provider from values that don't exist until
apply time — that fails on first run and makes `destroy` unreliable.
`02-platform` reads `01-infra` through `terraform_remote_state`.

## Node Groups & Workload Isolation

`01-infra/eks.tf` provisions three managed node groups:

| Node group | Taint | Label | Purpose |
| --- | --- | --- | --- |
| `controllers` | `workload=controller:NoSchedule` | `workload: controller` | CJOC and CloudBees CI Managed Controllers only. Graviton (ARM64). |
| `agents` | `workload=agent:NoSchedule` | `workload: agent` | Ephemeral Jenkins Pipeline build pods only. x86_64. |
| `system` | *(none — deliberately untainted)* | `workload: system` | Cluster add-ons that don't carry a `workload`-specific toleration: CoreDNS, EBS/EFS CSI controllers, Envoy Gateway, external-dns, aws-load-balancer-controller, cluster-autoscaler, metrics-server. |

Both `controllers` and `agents` are tainted so CI workloads land only where
intended. Since neither `autoscaler.tf`, `lbc.tf`, `envoy.tf`, nor
`external_dns.tf` sets a `nodeSelector`, those Deployments schedule onto the
untainted `system` pool automatically — no changes needed to their own
specs. The two exceptions that do need explicit tolerations:

- `01-infra/addons.tf`'s `aws_eks_addon.ebs_csi` / `efs_csi` set
  `configuration_values` with `controller.tolerations`, because the CSI
  driver *controller* Deployments (unlike their per-node DaemonSets) don't
  tolerate custom taints by default.
- `02-platform/cloudbees.tf`'s `OperationsCenter` sets both `NodeSelector`
  and `Tolerations` to force CJOC onto `controllers`. A toleration alone
  only grants permission to land there — `nodeSelector` is what actually
  requires it.

Any Jenkins Pipeline pod agent (Kubernetes plugin `PodTemplate`, inline
`podTemplate`, etc.) provisioned on this cluster needs a matching
`nodeSelector: {workload: agent}` and toleration for
`workload=agent:NoSchedule`, or its agent pods stay `Pending` indefinitely.

Dynamically-provisioned Managed Controller pods need the same treatment to
land on `controllers`. That's configured on CJOC's own "Kubernetes Master
Provisioning → Advanced" config (a raw StatefulSet merge patch, pasted in by
hand or wired in via CasC/groovy) — it's a CJOC-level setting, not something
this Terraform manages. Confirm it's actually applied by inspecting a live
controller's pod spec rather than assuming a config change took effect:

```sh
kubectl get pod <controller>-0 -o jsonpath='{.spec.nodeSelector}{"\n"}{.spec.tolerations}'
```

Note also that CJOC's StatefulSet merge does **not** deep-merge
`spec.affinity` — if the base template already sets `affinity.nodeAffinity`,
a patch adding to it can be silently dropped. `nodeSelector` and
`tolerations` are distinct top-level fields the base template doesn't
otherwise populate, so they aren't subject to that collision; don't rely on
an `affinity` addition taking effect until confirmed live.

## Prerequisites

- Terraform >= 1.5. `.tool-versions` here pins 1.15.8. Do not fall back to the
  asdf global default of 1.4.6 — it is EOL and cannot run AWS provider 5.9x
  (plugin protocol mismatch, which surfaces as an opaque "Unrecognized remote
  plugin message" rather than a version error). If `terraform` reports
  "No version is set for command terraform" in this directory, the pinned
  version is not installed yet: `asdf install terraform 1.15.8`.
- `aws` CLI v2 on PATH, authenticated to the target account. The `kubernetes`
  and `helm` providers shell out to `aws eks get-token`, so no token is ever
  written to state.
- A **public Route53 hosted zone** for the parent domain of `cjoc_host_name`,
  already existing. ACM validation and external-dns both write into it.

## Usage

```sh
cd 01-infra
cp terraform.tfvars.example terraform.tfvars   # set cjoc_host_name
terraform init
terraform apply

cd ../02-platform
terraform init
terraform apply
```

Then:

```sh
terraform -chdir=02-platform output cjoc_url
eval "$(terraform -chdir=02-platform output -raw kubeconfig_command)"
```

Optionally, add the standalone EC2 Client Controller:

```sh
cd ../03-ec2-controller
cp terraform.tfvars.example terraform.tfvars   # set ec2_controller_host_name
terraform init
terraform apply
```

```sh
terraform -chdir=03-ec2-controller output ec2_controller_url
```

That instance is reachable but **not yet attached to CJOC** as a managed
Client Controller — finish that from CJOC's "Add Controller" UI (or CasC);
it needs a controller-specific token Terraform has no way to obtain.

To configure a Jenkins "Kubernetes Cloud" on that Client Controller so it can
provision build agent pods in this cluster, `02-platform` also creates the
`jenkins-agent` ServiceAccount/Role/RoleBinding/token Secret it authenticates
with:

```sh
terraform -chdir=02-platform output -raw remote_agent_token
```

If that comes back empty (the token controller populates it asynchronously,
right after the Secret is first created), re-run `terraform apply` or use:

```sh
terraform -chdir=02-platform output -raw remote_agent_token_command | bash
```

See `../README-REMOTE-AGENT.md` for the rest of the Jenkins-side setup (API
URL, CA cert, namespace, wiring the token in as a credential).

Tear down in reverse: `03-ec2-controller` (if applied) first, then
`02-platform`, then `01-infra`. `03-ec2-controller` must go before
`02-platform` — it depends on the shared ALB that `02-platform` owns.

## Architecture

```
Internet
   │  HTTPS:443 — ACM cert, TLS terminates here
   ▼
 ALB  ◄── kubernetes_ingress_v1.cjoc_alb  (AWS Load Balancer Controller)
   │  HTTP, target-type: ip
   ▼
 kubernetes_service.envoy_stable  (ClusterIP, port 8443)
   │
   ▼
 Envoy pods ──► Gateway "https" listener (HTTP:8443)
   │
   ▼
 HTTPRoute (rendered by the CloudBees CI chart)
   │
   ▼
 CJOC / controllers
```

## Standalone EC2 Client Controller (`03-ec2-controller`)

Optional add-on, applied and destroyed independently of `02-platform`. It
provisions a second, EC2-hosted CloudBees CI Client Controller that shares
the same internet-facing ALB as the in-cluster CJOC, distinguished by
host-header routing rather than a second load balancer.

### Why a separate root module

Everything here is a plain AWS-account resource (EC2, IAM, ACM, ELBv2,
Route53) — no `kubernetes`/`helm`/`kubectl` provider is needed. Folding it
into `02-platform` would force every apply of this optional add-on to also
reconcile the cluster's Helm releases. It still depends on `02-platform`
having been applied (the shared ALB must already exist), but rather than
reading `02-platform`'s Terraform state, `alb.tf` looks the load balancer up
directly by the tags the AWS Load Balancer Controller stamps onto every ALB
it provisions from an Ingress (`ingress.k8s.aws/stack = <namespace>/<name>`).
That keeps this module working even if `02-platform`'s output shapes change,
at the cost of no compile-time dependency: if `02-platform` hasn't been
applied yet, the lookup simply fails at plan/apply time with "no matching
Load Balancer found". `envoy_gw_namespace` / `ingress_name` must match the
values `02-platform` used.

### What it creates

- **EC2 instance** (`compute.tf`) — latest Amazon Linux 2023, resolved via
  an SSM parameter rather than a pinned AMI ID. `user_data` (a small
  template in `templates/user_data.sh.tpl`) runs the CloudBees CI Client
  Controller as a Docker container on `controller_port`;
  `user_data_replace_on_change = true` means changing `controller_image` (or
  any other templated value) replaces the instance rather than silently
  drifting from what's actually running. The root EBS volume backs the
  container's `JENKINS_HOME`.
- **Security group** (`sg.tf`) — allows `controller_port`, 80 and 443 from
  the shared ALB's own security group (only `controller_port` is actually
  forwarded to by the target group), plus an SSH fallback scoped to
  `ssh_cidr` (defaults to the VPC CIDR). SSM Session Manager, via the
  instance's IAM role, works without SSH at all.
- **IAM role + instance profile** (`iam.tf`) — grants
  `AmazonSSMManagedInstanceCore` so Session Manager is the primary access
  path.
- **ACM certificate** (`acm.tf`) — DNS-validated for `ec2_controller_host_name`,
  attached to the shared HTTPS listener as an *additional* SNI certificate
  via `aws_lb_listener_certificate` — it never replaces the listener's
  default certificate, which `01-infra`/`02-platform` own.
- **Target group + listener rule** (`alb.tf`) — a host-header rule on the
  shared listener (`condition { host_header { values = [ec2_controller_host_name] } }`)
  forwards matching requests to this instance. `listener_rule_priority`
  claims a priority band above what the AWS Load Balancer Controller uses
  for its own Ingress-generated rules; a `PriorityInUse` error on apply
  means picking a different value.
- **Route53 alias A record** (`dns.tf`) — points directly at the shared ALB,
  the same mechanism external-dns uses for `cjoc_host_name` in `02-platform`,
  just declared statically here instead of reconciled by a controller
  (there's no Ingress for this record, so external-dns never sees it).
- **EKS API access rule** (`sg.tf`) — adds a 443 ingress rule to the
  *cluster's own* security group (exposed by `01-infra` as
  `cluster_security_group_id`), scoped to this instance's security group.
  Not needed by the Client Controller container itself, but `01-infra`
  enables `endpoint_private_access`, so any client inside the VPC — including
  this instance — resolves the cluster endpoint to a private ENI IP gated by
  that security group. Without the rule, ad-hoc `kubectl`/`curl` checks from
  this instance to the API server time out even though outbound internet
  access still works fine. Test with the `eks_api_test_command` output.

### After applying

The instance is reachable at `ec2_controller_url` but not yet attached to
CJOC as a managed Client Controller — that step needs a controller-specific
token only obtainable from CJOC's own "Add Controller" UI (or CasC), so it's
a manual follow-up regardless of how the instance was provisioned. Useful
outputs: `instance_id`, `instance_private_ip` (SSM Session Manager target),
`target_group_arn`, `security_group_id`, `eks_api_test_command`.

## Things to verify before the first apply

- **`lbc_chart_version`** in `02-platform/variables.tf` defaults to `1.14.0`,
  which was not verified against the registry. Check with
  `helm search repo eks/aws-load-balancer-controller --versions` and override
  if needed. A wrong pin fails loudly at `helm upgrade`.
- **`cluster_autoscaler_chart_version`** in `02-platform/variables.tf`
  defaults to `9.46.6`. Verify with
  `helm search repo autoscaler/cluster-autoscaler --versions`.
  `cluster_autoscaler_image_tag` defaults to `v<cluster_version>.0` derived
  from `01-infra`'s `cluster_version` output (cluster-autoscaler releases
  track EKS minor versions 1:1) — override it if that tag doesn't exist on
  `registry.k8s.io/autoscaling/cluster-autoscaler`.
- **`cloudbees_image_tag`** defaults to `latest`. Pin an explicit version —
  with `latest` every pod restart is a potential unplanned upgrade and
  rollbacks are non-deterministic.
- **`namespace_cloudbees` / `gateway_name`** default to `cloudbees-core` and
  `cloudbees-gateway`. Set them to match your environment if they differ.
- **`remote_agent_namespace`** defaults to `cloudbees-core-builds`. This is a
  namespace the CloudBees CI chart creates itself (`Agents.SeparateNamespace`),
  named `<namespace_cloudbees>-builds` — so change it if you change
  `namespace_cloudbees`. Verify it with `kubectl get ns` rather than trusting
  the default.
- **`03-ec2-controller/variables.tf`'s `controller_image`** defaults to
  `cloudbees/cloudbees-core-cm:latest`, a placeholder. Confirm the correct
  CloudBees CI Client Controller image/tag for your licensed version before
  applying.
- **`03-ec2-controller/variables.tf`'s `listener_rule_priority`** defaults to
  `100` and is not checked against existing rules on the shared listener —
  the AWS Load Balancer Controller manages its own Ingress-generated rule
  priorities separately. If `terraform apply` fails with `PriorityInUse`,
  pick a different value.
- **`policies/aws-load-balancer-controller.json`** was copied from
  `../../eks/iam_policy.json`. Refresh it when upgrading the controller:

  ```sh
  curl -o 01-infra/policies/aws-load-balancer-controller.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  ```

## State

All three modules use the default **local** backend, so `terraform.tfstate`
sits on disk and is gitignored. For anything shared or long-lived, move to S3
with DynamoDB locking before a second person touches it.
