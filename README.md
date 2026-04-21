# CloudBees CI with Gateway API

This repository provides a comprehensive guide and ready-to-use scripts for deploying CloudBees CI on Google Kubernetes Engine (GKE) and Azure Kubernetes Service (AKS) using the modern [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

## 🚀 Purpose

The goal of this project is to demonstrate how to replace traditional Ingress-based networking with the more expressive and role-oriented Gateway API. We provide three distinct architectural paths:

1. **GKE Native (`gke/google-gw`)**: Leveraging Google Cloud's managed Gateway controller and Regional External Application Load Balancers.
2. **AKS Native (`aks/azure-appgw`)**: Leveraging Azure Cloud's managed Gateway controller and Regional External Application Load Balancers.
3. **Envoy Gateway**
    * (`gke/envoy`)*: Utilizing the cloud-agnostic Envoy Gateway controller for a uniform experience across different Kubernetes environments.
    * (`aks/envoy`)*: Utilizing the cloud-agnostic Envoy Gateway controller for a uniform experience across different Kubernetes environments.

## 📂 Project Structure

* **[gke/google-gw](./gke/google-gw)**: GKE-specific implementation using native GCP policies (`HealthCheckPolicy`, `GCPBackendPolicy`).
* **[gke/envoy](./gke/envoy)**: Cloud-agnostic implementation using Envoy-specific extension APIs (`BackendTrafficPolicy`) for health checks and session affinity.
* **[aks](./aks)**: AKS-native Gateway API implementation.
* **[scripts](./scripts)**: Common utility scripts, including SSL certificate generation.

## ⚙️ Configuration

Each environment (GKE, AKS) requires a `.env` file for configuration. Templates are provided as `.env-template`.

1. **Locate the directory** for your target environment.
2. **Copy the template**:

    ```bash
    cp .env-template .env
    ```

3. **Edit the `.env` file** and replace placeholders (e.g., `<YOUR_PROJECT_ID>`) with your actual values.

## 📊 Architecture Comparison

| Feature | GKE Native (`google-gw`) | Envoy Gateway (`envoy`) |
| :--- | :--- | :--- |
| **Controller** | GKE Gateway Controller (GCP Managed) | Envoy Gateway (OSS Controller in-cluster) |
| **Data Plane** | Google Cloud Load Balancing (ALB) | Envoy Proxy (running on k8s nodes) |
| **Portability** | Locked to GCP/GKE | Cloud-agnostic (EKS, AKS, on-prem) |
| **Networking** | Requires GCP Proxy-only subnet | Standard GKE networking |
| **Health Checks** | `HealthCheckPolicy` (GCP Specific) | `BackendTrafficPolicy` (Envoy specific) |
| **Session Affinity** | `GCPBackendPolicy` (GCP Specific) | `BackendTrafficPolicy` (Envoy specific) |
| **Operational Overhead** | Low (Managed by Google) | Medium (Managed by DevOps team) |
| **Config Propagation** | Minute-scale (GCP Control Plane) | Second-scale (Real-time via xDS) |

## 🛠 Prerequisites

Ensure you have the following tools installed and configured:

* **CLI Tools**: `gcloud`, `kubectl` (with GKE auth plugin), `helm`.
* **Infrastructure**: A GKE cluster (v1.24+) or AKS cluster.
* **Certificates**: A domain name and corresponding SSL certificates (or use the provided generation script for self-signed certs).

## ⚡️ Quick Start

### 1. Authenticate to your cluster

```bash
# For GKE
cd gke/
./auth.sh
```

### 2. Generate SSL certificates (Optional/Self-signed)

```bash
cd scripts/
./generate-ssl-cert.sh your-hostname.example.com
```

### 3. Deploy the Gateway & CloudBees CI

```bash
# Choose your implementation
cd gke/envoy/  # or gke/google-gw/
./install.sh
```

## 🔧 Troubleshooting

### Stuck "Terminating" Resources

On GKE, if you delete a Gateway or Gateway API CRDs while they are still in use, they can get stuck in a "Terminating" state due to finalizers. To resolve this:

```bash
# Patch the resource to remove finalizers
kubectl patch gateway <name> -n <namespace> -p '{"metadata":{"finalizers":null}}' --type=merge

# If the CRD itself is stuck
kubectl patch crd gateways.gateway.networking.k8s.io -p '{"metadata":{"finalizers":null}}' --type=merge
```

### 503 No Healthy Upstream (Envoy)

Envoy's `BackendTrafficPolicy` enforces active health checks. Ensure your `cjoc` or controller pods are not only running but also healthy from an application perspective.

---

*Maintained by the CloudBees Professional Services team.*
