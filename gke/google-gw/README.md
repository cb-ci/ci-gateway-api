# CloudBees CI on GKE with Gateway API

This repository contains scripts and configurations to deploy CloudBees CI on Google Kubernetes Engine (GKE) using the modern **GKE Gateway API**.

## Overview

Traditional GKE Ingress is being succeeded by the Gateway API, which provides a more expressive and role-oriented approach to networking. This setup demonstrates how to:

- Provision a **Regional External Application Load Balancer** via the GKE Gateway controller.
- Deploy  a **Gateway** to route traffic to the CloudBees CI cluster.
- Configure **TLS Termination** using Kubernetes secrets.
- Implement a **HealthCheckPolicy** to handle CloudBees CI's custom health paths.
- Enable **GCPBackendPolicy** for sticky sessions for the HA controller.
- Deploy CloudBees CI Operations Center (`cjoc`) via Helm.

## Prerequisites

- A GKE cluster (version 1.24+ recommended).
- Gateway API CRDs installed and the Gateway controller enabled.
- `gcloud`, `kubectl`, and `helm` CLI tools configured.
- Self-signed or CA-signed certificates (`jenkins.pem` and `server.key`) in the root directory. (see `./generate-certs.sh` for an example of how to generate self-signed certificates)

## Getting Started

### 1. Installation

Run the provided installation script. It will enable the necessary GCP services, create the proxy-only subnet (if missing), and deploy the Gateway resources and CloudBees CI.

```bash
chmod +x install.sh
./install.sh
```

### 2. Accessing Operations Center

Once the deployment is complete and the load balancer has synced (this may take 2-5 minutes), retrieve your initial admin password:

```bash
kubectl exec -ti cjoc-0 -n cloudbees-gatewayapi -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Visit the URL configured in `install.sh` (default: `https://gateway.acaternberg.flow-training.beescloud.com/cjoc`).

For a detailed look at the traffic flow and component relationships, see [DIAGRAM.md](./DIAGRAM.md).

## Architecture

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
curl -c cokkie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -b cokkie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -c cokkie1.txt  -b cokkie.txt  -v -L -k https://gateway.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
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
