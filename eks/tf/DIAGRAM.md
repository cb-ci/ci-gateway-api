# Architecture diagrams (Terraform)

Two views of what the Terraform stacks in this directory build. Layout follows
the diagram in [`../eksctl/README.md`](../eksctl/README.md).

| Stack | Creates |
| --- | --- |
| [`01-infra`](01-infra) | VPC, EKS cluster + node groups, EKS add-ons, IRSA / Pod Identity roles, EFS, CJOC ACM certificate |
| [`02-platform`](02-platform) | Envoy Gateway, Gateway/ClientTrafficPolicy, ALB Ingress, AWS LB Controller, external-dns, cluster-autoscaler, EFS StorageClass, CloudBees CI Helm release, remote-agent ServiceAccount |
| [`03-ec2-controller`](03-ec2-controller) | *Optional.* EC2 Client Controller on the shared ALB |

## 1. CloudBees CI on EKS only (`01-infra` + `02-platform`)

```mermaid
flowchart TB
    User(("Internet users"))

    subgraph DNS["Route53 public hosted zone"]
        direction LR
        R53_CJOC["A (alias)\ncjoc.___\nmanaged by external-dns"]
    end

    subgraph AWSAcct["AWS account-level resources"]
        direction LR
        ACM["ACM certificate\n(cjoc, DNS-validated)\n01-infra/acm.tf"]
    end

    subgraph VPC["VPC (single-AZ workers)"]
        subgraph Public["Public subnets"]
            ALB["Internet-facing ALB\nHTTPS :443, host-header routing\nHTTP :80 redirects to 443"]
            NAT["NAT Gateway"]
        end

        subgraph Private["Private subnets"]
            subgraph EKS["EKS cluster"]
                LBC["aws-load-balancer-controller"]
                CA["cluster-autoscaler"]
                EDNS["external-dns\n(Pod Identity)"]
                EnvoyGW["Envoy Gateway + Gateway\nClientTrafficPolicy:\nKeepUnchanged slashes, 1 trusted XFF hop"]
                EnvoySvc["Stable Service envoy-*-stable\n(ClusterIP, selects Envoy pods)"]
                CJOC["CJOC / CloudBees CI\nStatefulSet + PVC\nHTTPRoute from the Helm chart"]
                CtrlA["Managed Controller 1 (HA)\nDeployment, 2 replicas\nshared RWX PVC"]
                CtrlB["Managed Controller 2 (HA)\nDeployment, 2 replicas\nshared RWX PVC"]
                Agents["Build agent pods\nnamespace cbci-builds"]
                NGControllers["Node group: controllers\n(tainted)"]
                NGAgents["Node group: agents\n(tainted)"]
                NGSystem["Node group: system\n(untainted — CoreDNS, CSI\ncontrollers, LBC, CA, EDNS,\nEnvoy Gateway)"]
            end
        end

        EFS[("EFS file system\nStorageClass efs-sc")]
        EBS[("EBS volumes\ngp2 / EBS CSI")]
    end

    User -->|HTTPS| R53_CJOC --> ALB
    ALB -->|"Ingress cjoc-alb\nhost: cjoc.___, target-type ip"| EnvoySvc --> EnvoyGW --> CJOC
    ALB -. certificate .-> ACM

    LBC -. reconciles Ingress .-> ALB
    EDNS -. upserts .-> R53_CJOC
    CJOC --> EFS
    EnvoyGW -->|"HTTPRoute /controller-1/, /controller-2/\nsame host as CJOC"| CtrlA
    EnvoyGW --> CtrlB
    CJOC -. "provisions (Kubernetes API)" .-> CtrlA
    CJOC -. provisions .-> CtrlB
    CtrlA --> EFS
    CtrlB --> EFS
    CtrlA -. provisions .-> Agents
    CtrlB -. provisions .-> Agents
    NGControllers --- CtrlA
    NGControllers --- CtrlB
    CJOC -. provisions .-> Agents
    NGControllers --- CJOC
    NGAgents --- Agents
    NGSystem --- LBC
    NGSystem --- CA
    NGSystem --- EDNS
    NGSystem --- EnvoyGW
    CA -. resizes on pod pressure .-> NGControllers
    CA -. resizes on pod pressure .-> NGAgents
    CA -. resizes on pod pressure .-> NGSystem
    Private -->|egress| NAT
```

TLS terminates at the ALB; Envoy listens on plain HTTP behind it, but the
Operations Center is configured with `Protocol: https` so generated URLs stay
correct.

The two Managed Controllers are created from the Operations Center UI, not by
Terraform. Each runs in High Availability mode: a Deployment with two replicas
that share one ReadWriteMany PVC on `efs-sc` (EFS), which is why a ReadWriteOnce
class such as `gp2` cannot be used for them. Both are reached on the CJOC host
under their own path through Envoy. The node names and paths above are
placeholders, and the controllers must be scheduled onto the `controllers` node
group (see `controller-statefullset-patch.yaml` in the eksctl directory; note it
patches a StatefulSet, so an equivalent patch for HA Deployments is needed).

## 2. With the optional EC2 Client Controller (`03-ec2-controller`)

Same core as above. Dashed nodes are added by `03-ec2-controller`; it reuses
the existing ALB and HTTPS listener rather than creating a second load balancer.

```mermaid
flowchart TB
    User(("Internet users"))

    subgraph DNS["Route53 public hosted zone"]
        direction LR
        R53_CJOC["A (alias)\ncjoc.___\nmanaged by external-dns"]
        R53_EC2["A (alias)\nec2-controller.___\nmanaged by 03-ec2-controller"]
    end

    subgraph AWSAcct["AWS account-level resources"]
        direction LR
        ACM["ACM certificates\ncjoc (01-infra)\nec2-controller (03-ec2-controller)"]
        SSM["AWS Systems Manager\nSession Manager"]
    end

    subgraph VPC["VPC (single-AZ workers)"]
        subgraph Public["Public subnets"]
            ALB["Shared internet-facing ALB\nHTTPS :443, host-header routing\nSNI certificates"]
            NAT["NAT Gateway"]
        end

        subgraph Private["Private subnets"]
            subgraph EKS["EKS cluster"]
                LBC["aws-load-balancer-controller"]
                CA["cluster-autoscaler"]
                EDNS["external-dns"]
                EnvoySvc["Stable Service envoy-*-stable\n(ClusterIP)"]
                EnvoyGW["Envoy Gateway + HTTPRoute"]
                CJOC["CJOC / CloudBees CI\nStatefulSet + PVC"]
                CtrlA["Managed Controller 1 (HA)\nDeployment, 2 replicas\nshared RWX PVC"]
                CtrlB["Managed Controller 2 (HA)\nDeployment, 2 replicas\nshared RWX PVC"]
                RemoteSA["ServiceAccount + token\nfor remote agents\nnamespace cbci-builds"]
                Agents["Build agent pods"]
                NGControllers["Node group: controllers\n(tainted)"]
                NGAgents["Node group: agents\n(tainted)"]
                NGSystem["Node group: system\n(untainted add-ons)"]
                EKSAPI["EKS API endpoint\ncluster security group"]
            end

            EC2["EC2 instance (Amazon Linux 2023)\nCloudBees CI Client Controller\nDocker, :8080\nown security group + instance profile"]
            TG["Target group\ntype instance, health /login"]
        end

        EFS[("EFS file system\nStorageClass efs-sc")]
        EBS[("EBS root volume\nJENKINS_HOME")]
    end

    User -->|HTTPS| R53_CJOC --> ALB
    User -->|HTTPS| R53_EC2 --> ALB

    ALB -->|"host: cjoc.___"| EnvoySvc --> EnvoyGW --> CJOC
    ALB -->|"host: ec2-controller.___\nlistener rule"| TG --> EC2
    ALB -. SNI certificates .-> ACM

    LBC -. reconciles Ingress .-> ALB
    EDNS -. upserts .-> R53_CJOC
    CJOC --> EFS
    EnvoyGW -->|"HTTPRoute /controller-1/, /controller-2/\nsame host as CJOC"| CtrlA
    EnvoyGW --> CtrlB
    CJOC -. "provisions (Kubernetes API)" .-> CtrlA
    CJOC -. provisions .-> CtrlB
    CtrlA --> EFS
    CtrlB --> EFS
    CtrlA -. provisions .-> Agents
    CtrlB -. provisions .-> Agents
    NGControllers --- CtrlA
    NGControllers --- CtrlB
    EC2 --> EBS
    CJOC -. provisions .-> Agents
    EC2 -. "connects as ServiceAccount\n(443, SG rule from EC2 SG)" .-> EKSAPI
    EKSAPI -. creates agent pods .-> Agents
    RemoteSA --- EKSAPI
    EC2 -. IAM instance profile .-> SSM

    NGControllers --- CJOC
    NGAgents --- Agents
    NGSystem --- LBC
    NGSystem --- CA
    NGSystem --- EDNS
    NGSystem --- EnvoyGW
    CA -. resizes on pod pressure .-> NGControllers
    CA -. resizes on pod pressure .-> NGAgents
    CA -. resizes on pod pressure .-> NGSystem
    Private -->|egress| NAT

    classDef optional stroke-dasharray: 5 5
    class EC2,TG,R53_EC2,EBS optional
```

The EC2 stack looks up the ALB by its `ingress.k8s.aws/stack` tag, so
`02-platform` must be applied first. The EC2 instance's security group accepts
traffic only from the ALB's security group (SSH is limited to the VPC CIDR
unless `ssh_cidr` is set), and `03-ec2-controller` adds a 443 ingress rule on
the EKS cluster security group so the controller can reach the Kubernetes API.
