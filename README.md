# CloudBees CI with Gateway API

This repository provides a comprehensive guide and ready-to-use scripts for deploying CloudBees CI on Google Kubernetes Engine (GKE) and Azure Kubernetes Service (AKS) using the modern [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

## Purpose

The goal of this project is to demonstrate how to replace traditional Ingress-based networking with the more expressive and role-oriented Gateway API. We provide three distinct architectural paths:

1. **GKE Native (`gke/google-gw`)**: Leveraging Google Cloud's managed Gateway controller.
2. **AKS Native (`aks/azure-appgw`)**: Leveraging Azure Cloud's managed Application Gateway (AGIC).
3. **Envoy Gateway (`gke/envoy`, `aks/envoy`)**: Utilizing the cloud-agnostic Envoy Gateway controller.

## Project Structure

* **[gke/](file:///Users/acaternberg/projects/cloudbees-ci/ci-gateway-api/gke)**: GKE-specific implementations.
* **[aks/](file:///Users/acaternberg/projects/cloudbees-ci/ci-gateway-api/aks)**: AKS-specific implementations.
* **[scripts/](file:///Users/acaternberg/projects/cloudbees-ci/ci-gateway-api/scripts)**: Shared utility library (`_functions.sh`) and core tools.

## Configuration

1. **Copy the root template**:

    ```bash
    cp .env-template .env
    ```

2. **Edit the `.env` file** with your specific cloud provider details.
3. **Link the `.env` file** to the specific provider directory if needed, or create local ones. The scripts will look for `.env` in their respective directories.

## Prerequisites

Ensure you have the following tools installed:

* **CLI Tools**: `gcloud` (for GKE), `az` (for AKS), `kubectl`, `helm`.
* **Shared Library**: All scripts rely on `scripts/_functions.sh`.

## Quick Start

### 1. Authenticate to your cluster

```bash
# For GKE
cd gke/
./auth.sh

# For AKS
cd aks/
./auth.sh
```

### 3. Deploy the Gateway & CloudBees CI

```bash
# Example: GKE with Envoy Gateway
cd gke/envoy/
./install.sh
```

## Script Standards

* **Logging**: All scripts use a consistent logging format (INFO, WARN, ERROR, SUCCESS).
* **Validation**: Scripts validate required environment variables before execution.
* **Idempotency**: Installation scripts are designed to be run multiple times safely.

---

*Maintained by the CloudBees Professional Services team.*
