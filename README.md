# CloudBees CI with Gateway API

This repository provides a comprehensive guide and ready-to-use scripts for deploying CloudBees CI on Google Kubernetes Engine (GKE) and Azure Kubernetes Service (AKS) using the modern [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

WARNING: This repository contains very raw deployment approaches. CloudBees released the official documentation on this topic, and the Gateway API is GA in the meantime. Do not use this repository for production. The proper way forward is to use [CloudBees documentation](https://docs.cloudbees.com/docs/cloudbees-ci/latest/kubernetes-install-guide/gateway-api-intro).

## Purpose

The goal of this project is to demonstrate how to replace traditional Ingress-based networking with the more expressive and role-oriented Gateway API. We provide three distinct architectural paths:

1. **GKE Native (`gke/google-gw`)**: Leveraging Google Cloud's managed Gateway controller.
2. **AKS Native (`aks/azure-appgw`)**: Leveraging Azure Cloud's managed Application Gateway (AGIC).
3. **Envoy Gateway (`gke/envoy`, `aks/envoy`)**: Utilizing the cloud-agnostic Envoy Gateway controller.

## Project Structure

* **[gke/](./gke)**: GKE-specific implementations and authentication logic.
* **[aks/](./aks)**: AKS-specific implementations and authentication logic.
* **[scripts/](./scripts)**: Shared utility library (`_functions.sh`), SSL generation, and test tools.

## Prerequisites

Ensure you have the following tools installed and configured:

* **CLI Tools**: `kubectl`, `helm`, and your cloud CLI (`gcloud` or `az`).
* **Environment Configuration**: Access to a Kubernetes cluster (GKE or AKS).
* **Domain**: A valid domain name for your CloudBees CI instance.

## Getting Started

Follow these steps for a consistent deployment experience:

### 1. Global Setup

Copy the environment template and configure your global variables (Domain, Cloud Project IDs, etc.):

```bash
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
```

### 3. Deploy an Implementation

Navigate to the specific implementation directory and run the installation:

```bash
# Example: GKE with Envoy Gateway
cd gke/envoy/
./install.sh
```

## Maintenance and Standards

* **Shared Functions**: All scripts utilize [`scripts/_functions.sh`](./scripts/_functions.sh) for consistent logging and validation.
* **Environment Loading**: Scripts automatically source the root `.env` file.
* **SSL Certificates**: Certificates are generated and stored in the project root by default.

---

*Maintained by the CloudBees Professional Services team.*
