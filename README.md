# CloudBees CI with Gateway API

This repository provides a comprehensive guide and ready-to-use scripts for deploying CloudBees CI on Google Kubernetes Engine (GKE) using the modern [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

## Purpose

The goal of this project is to demonstrate how to replace traditional Ingress-based networking with the more expressive and role-oriented Gateway API. We provide two distinct architectural paths to help you choose the best fit for your infrastructure needs:

1. **GKE Native (`gke/google-gw`)**: Leveraging Google Cloud's managed Gateway controller and Regional External Application Load Balancers.
2. **AKS Native (`aks/`)**: Leveraging Azure Cloud's managed Gateway controller and Regional External Application Load Balancers.
3. **Envoy Gateway (`gke/envoy`)**: Utilizing the cloud-agnostic Envoy Gateway controller for a uniform experience across different Kubernetes environments.

## Project Structure

- **[gke/google-gw](./gke/google-gw)**: GKE-specific implementation using native GCP policies (`HealthCheckPolicy`, `GCPBackendPolicy`).
- **[gke/envoy](./gke/envoy)**: Cloud-agnostic implementation using Envoy-specific extension APIs (`BackendTrafficPolicy`) for health checks and session affinity.

## Architecture Comparison

| Feature | GKE Native (`google-gw`) | Envoy Gateway (`envoy`) |
| :--- | :--- | :--- |
| **Controller** | GKE Gateway Controller (GCP Managed) | Envoy Gateway (OSS Controller in-cluster) |
| **Data Plane** | Google Cloud Load Balancing (ALB) | Envoy Proxy (running on GKE nodes) |
| **Portability** | Locked to GCP/GKE | Cloud-agnostic (works on EKS, AKS, on-prem) |
| **Networking** | Requires GCP Proxy-only subnet | Standard GKE networking (no special subnet) |
| **Health Checks** | `HealthCheckPolicy` (GCP Specific) | `BackendTrafficPolicy` (Envoy Proxy specific) |
| **Session Affinity** | `GCPBackendPolicy` (GCP Specific) | `BackendTrafficPolicy` (Envoy Proxy specific) |
| **Operational Overhead** | Low (Managed by Google) | Medium (Managed by DevOps team) |
| **Config Propagation** | Minute-scale (GCP Control Plane) | Second-scale (Real-time via xDS) |

## Pros & Cons

### GKE Native (`google-gw`)

- **✅ Pros**:
  - **Fully Managed**: Google handles the load balancer's availability and scaling.
  - **Integration**: Seamlessly integrate with Cloud Armor (WAF), IAP, and GCP Certificates.
  - **Enterprise Ready**: Backed by GCP's global infrastructure.
- **❌ Cons**:
  - **Cloud Specific**: Configuration is not portable to other clouds.
  - **Subnet Requirement**: Requires a dedicated `REGIONAL_MANAGED_PROXY` subnet.

### Envoy Gateway (`envoy`)

- **✅ Pros**:
  - **Cloud Agnostic**: Identical configuration on GKE, EKS, or Bare Metal.
  - **Fast Propagations**: Real-time traffic management without waiting for GCP LB updates.
  - **Feature Rich**: Access to advanced Envoy filters and extensibility.
- **❌ Cons**:
  - **Self-Managed**: You are responsible for scaling and updating the Envoy pods.
  - **Resource Cost**: Consumes CPU and Memory within your GKE node pools.

---

*Maintained by the CloudBees Professional Services team.*
