# CloudBees CI on GKE with Native Gateway API

This directory contains resources to deploy CloudBees CI on GKE using the native **Google Cloud Gateway Controller**, which leverages Regional External Application Load Balancers.

## Overview

This setup provides high-performance, managed load balancing that integrates directly with GCP services. This setup provides:

- **Regional Management**: Uses Regional Application Load Balancers for lower latency.
- **Native Health Checks**: Uses GCP-specific `HealthCheckPolicy`.
- **Managed Session Affinity**: Uses `GCPBackendPolicy` for robust cookie-based stickiness.

## Prerequisites

- Access to a GKE cluster with Gateway API enabled.
- Completed authentication via [**`gke/auth.sh`**](../auth.sh).
- This directory's own [**`.env`**](./.env) file configured — copy it from `.env-template` (separate from `gke/.env`, which `gke/auth.sh` uses):

```bash
cd gke/google-gw
cp .env-template .env
# Edit .env with your specific details
```

## Getting Started

### 1. Installation

Run the installation script to configure networking and deploy CloudBees CI. It generates a self-signed SSL certificate for `CJOC_HOST_NAME` automatically — no manual certificate step needed.

```bash
chmod +x install.sh
./install.sh
```

### 2. Verification

Retrieve the initial admin password and visit the URL provided at the end of the installation script:

```bash
kubectl exec -ti cjoc-0 -n cloudbees-google-gw -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Visit the URL configured in `install.sh` (default: `https://gateway.acaternberg.flow-training.beescloud.com/cjoc`).

## Architecture

For a detailed look at the traffic flow and component relationships, see [DIAGRAM.md](./DIAGRAM.md).

### Key Components

- **`install.sh`**: Main orchestration script.

## Troubleshooting

### 503 Service Unavailable

If you encounter a 503 "no healthy upstream" error shortly after installation, it is likely due to the Load Balancer propagation delay. The `HealthCheckPolicy` ensures the backends become healthy once the configuration has fully synced to the GCP control plane.

### Test with curl

```bash
curl -v -L -k  https://gateway.acaternberg.flow-training.beescloud.com/cjoc/whoAmI/api/json
# Requires controller "ha" to be created before running these commands
curl -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -c cookie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -b cookie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -c cookie1.txt  -b cookie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
```

## Reference Documentation

| Topic | Documentation Link |
| :--- | :--- |
| **GKE Gateway API Overview** | [Google Cloud Docs](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api) |
| **GKE Gateway Controller examples** | [Configuration Examples](https://oneuptime.com/blog/post/2026-02-09-gke-gateway-controller-http-routing/view) |
| **GKE Gateway Controller examples1** | [Configuration Examples1](https://oneuptime.com/blog/post/2026-02-17-how-to-configure-gke-gateway-controller-for-advanced-http-routing-and-header-based-matching/view) |
| **GCPBackendPolicy** | [Sticky Sessions & Timeouts](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources#gcpbackendpolicy) |
| **HealthCheckPolicy** | [Custom Health Checks](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources#healthcheckpolicy) |
| **Kubernetes Gateway API** | [Official SIG Docs](https://gateway-api.sigs.k8s.io/) |
