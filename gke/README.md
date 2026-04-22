# CloudBees CI on Google Kubernetes Engine (GKE)

This directory contains implementations for deploying CloudBees CI on GKE using the Gateway API. We provide both a cloud-agnostic Envoy Gateway approach and a GCP-native Gateway API approach.

## Choosing an Approach

| Feature | Envoy Gateway (`./envoy`) | GCP Gateway API (`./google-gw`) |
| :--- | :--- | :--- |
| **Stability** | Mature OSS Component | Stable managed service |
| **Portability** | High (Multi-cloud) | Low (GCP only) |
| **Load Balancer** | In-cluster Envoy Proxies | Regional External ALB |
| **Networking** | Standard GKE Networking | Requires Proxy-only subnet |
| **Cost** | Included in cluster resources | ALB per-hour/per-GB pricing |

## Getting Started

### 1. Authenticate to the Cluster
The `auth.sh` helper script ensures you are authenticated with GCP and have the correct `kubectl` context. It sources the global configuration from the root `.env`.

```bash
chmod +x auth.sh
./auth.sh
```

### 2. Implementation Setup
Choose your implementation and navigate to its directory:

```bash
cd envoy/      # For Envoy Gateway
# OR
cd google-gw/  # For GCP Native Gateway
```

### 3. Deployment
Run the installation script. It will handle CRD management, namespace creation, TLS secrets, and the CloudBees CI Helm chart.

```bash
./install.sh
```

## Directory Structure

*   **[envoy/](./envoy)**: Uses the Envoy Gateway controller. Best for portable, cloud-agnostic setups.
*   **[google-gw/](./google-gw)**: Uses the GKE Gateway Controller. Best for leveraging GCP managed services like Cloud Armor and IAP.
*   **[auth.sh](./auth.sh)**: Standardized GKE authentication script.

## Reference Documentation

*   [GKE Gateway API Concepts](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api)
*   [Envoy Gateway Documentation](https://gateway.envoyproxy.io/docs/)
