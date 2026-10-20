# CloudBees CI with Gateway API

This repository provides a comprehensive guide and ready-to-use scripts for deploying CloudBees CI on Google Kubernetes Engine (GKE), Azure Kubernetes Service (AKS) and Amazon Elastic Kubernetes Service (EKS) using the modern [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

WARNING: This repository contains very raw deployment approaches. CloudBees released the official documentation on this topic, and the Gateway API is GA in the meantime. Do not use this repository for production. The proper way forward is to use [CloudBees documentation](https://docs.cloudbees.com/docs/cloudbees-ci/latest/kubernetes-install-guide/gateway-api-intro).

## Purpose

The goal of this project is to demonstrate how to replace traditional Ingress-based networking with the more expressive and role-oriented Gateway API. We provide four distinct architectural paths:

1. **GKE Native (`gke/google-gw`)**: Leveraging Google Cloud's managed Gateway controller.
2. **AKS Native (`aks/azure-appgw`)**: Leveraging Azure Cloud's managed Application Gateway (AGIC).
3. **Envoy Gateway (`gke/envoy`, `aks/envoy`)**: Utilizing the cloud-agnostic Envoy Gateway controller.
4. **EKS with Envoy Gateway and a remote Client Controller (`eks/`)**: An EKS cluster (provisioned with either `eksctl` scripts or Terraform) running Envoy Gateway behind an AWS Application Load Balancer, plus an optional EC2-hosted Client Controller whose Kubernetes Cloud schedules build agent pods in the cluster.

## Project Structure

* **[gke/](./gke)**: GKE-specific implementations and authentication logic.
* **[aks/](./aks)**: AKS-specific implementations and authentication logic.
* **[eks/](./eks)**: EKS-specific implementations (see [`eks/README.md`](./eks/README.md)):
  * `eks/eksctl/`: numbered shell scripts for the cluster, EFS, AWS Load Balancer Controller, Cluster Autoscaler, Envoy Gateway, CloudBees CI, ExternalDNS, the EC2 Client Controller and the remote-agent ServiceAccount (see [`eks/eksctl/README.md`](./eks/eksctl/README.md)).
  * `eks/tf/`: Terraform equivalent in three root modules: `01-infra`, `02-platform`, and the optional `03-ec2-controller` (see [`eks/tf/README.md`](./eks/tf/README.md)).
  * `eks/cloudbees-core/`: local Helm chart used for the CloudBees CI install.
* **[scripts/](./scripts)**: Shared utility library (`_functions.sh`), SSL generation, and test tools.

## Prerequisites

Ensure you have the following tools installed and configured:

* **CLI Tools**: `kubectl`, `helm`, and your cloud CLI (`gcloud`, `az` or `aws`; plus `eksctl` or `terraform` for EKS).
* **Environment Configuration**: Access to a Kubernetes cluster (GKE, AKS or EKS).
* **Domain**: A valid domain name for your CloudBees CI instance.

## Getting Started

Follow these steps for a consistent deployment experience:

### 1. Global Setup

Copy the environment template and configure your global variables (Domain, Cloud Project IDs, etc.):

```bash
# For GKE
cd gke
cp .env-template .env
# Edit .env with your specific details

# For AKS
cd aks
cp .env-template .env
# Edit .env with your specific details

# For EKS (eksctl scripts; Terraform uses terraform.tfvars instead, see eks/tf/README.md)
cd eks/eksctl
cp .env-template .env
# Edit .env with your specific details
```

### 2. Cloud Authentication

Navigate to your target cloud directory and authenticate to your cluster:

```bash
# For GKE
cd gke/
./auth.sh

# For AKS
cd aks/
./auth.sh

# For EKS
cd eks/eksctl/
./00-login.sh
```

### 3. Deploy an Implementation

Navigate to the specific implementation directory and run the installation:

```bash
# Example: GKE with Envoy Gateway
cd gke/envoy/
./01-install-envoy.sh

# Example: EKS (eksctl); scripts are numbered in run order
cd eks/eksctl/
./01-createCluster.sh
```

For the full EKS sequence, including the Terraform path, follow [`eks/README.md`](./eks/README.md).

## Maintenance and Standards

* **Shared Functions**: All scripts utilize [`scripts/_functions.sh`](./scripts/_functions.sh) for consistent logging and validation.
* **Environment Loading**: Scripts source the `.env` file from their cloud directory (`gke/.env`, `aks/.env` or `eks/eksctl/.env`), not a repository-root `.env`. The `gke/google-gw` implementation additionally requires its own `gke/google-gw/.env` (copy it from `gke/google-gw/.env-template`).
* **SSL Certificates**: Self-signed certificates are generated automatically by each `install.sh` and stored in the `ssl/` directory at the project root by default; you don't need to generate them manually first.

---

*Maintained by the CloudBees Professional Services team.*
