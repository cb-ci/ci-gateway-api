# CloudBees CI on AKS with Envoy Gateway

This directory contains scripts and configurations to deploy CloudBees CI on Azure Kubernetes Service (AKS) using **Envoy Gateway** — a cloud-agnostic, Kubernetes-native implementation of the Gateway API.

## Overview

This setup is the cloud-agnostic equivalent of the [`../azure-appgw`](../azure-appgw) setup which uses Azure's Application Gateway Ingress Controller. By using Envoy Gateway, the same Gateway API resources work on any Kubernetes distribution without Azure-specific CRDs.

Key capabilities:

- Deploy **Envoy Gateway** as the Gateway API controller via Helm.
- Provision a **GatewayClass** backed by Envoy's data plane.
- Configure **TLS Termination** using Kubernetes secrets.
- Implement **active health checks** via `BackendTrafficPolicy`.
- Enable **cookie-based sticky sessions** via `BackendTrafficPolicy` consistent hash.
- Deploy CloudBees CI Operations Center (`cjoc`) via Helm.

## Prerequisites

- An AKS cluster (version 1.24+ recommended).
- `az`, `kubectl`, and `helm` CLI tools configured and authenticated.
- Self-signed or CA-signed certificates (`jenkins.pem` and `server.key`). See `../scripts/generate-ssl-cert.sh` to generate self-signed certificates.

## Getting Started

### 1. Generate Certificates (if needed)

```bash
CJOC_HOST=gateway-envoy.acaternberg.flow-training.beescloud.com ../scripts/generate-ssl-cert.sh
```

### 2. Installation

Run the installation script. It will:

1. Install **Envoy Gateway** into the `envoy-gateway-system` namespace via Helm.
2. Create the `cloudbees-envoy` namespace and TLS secret.
3. Apply the `GatewayClass`, `Gateway`, `HTTPRoute`, and `BackendTrafficPolicy` resources.
4. Deploy **CloudBees CI** via Helm.
5. Wait for the Gateway's external IP to be assigned.

```bash
chmod +x install.sh
./install.sh
```

### 3. Accessing Operations Center

Once the deployment is complete, retrieve the initial admin password:

```bash
kubectl exec -ti cjoc-0 -n cloudbees-envoy -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Visit: `https://gateway-envoy.acaternberg.flow-training.beescloud.com/cjoc`

## Architecture

For a detailed look at the traffic flow and component relationships, see [DIAGRAM.md](./DIAGRAM.md).

### Key Resources

| Resource | Kind | Purpose |
| :--- | :--- | :--- |
| `eg` | `GatewayClass` | Links Gateway resources to the Envoy data plane |
| `cloudbees-gateway` | `Gateway` | HTTPS listener on :443 with TLS termination |
| `cloudbees-route` | `HTTPRoute` | Path-based routing: `/cjoc` and `/ha` |
| `cjoc-health-check-policy` | `BackendTrafficPolicy` | Active HTTP health check on `/cjoc/health/` |
| `ha-traffic-policy` | `BackendTrafficPolicy` | Active health check + cookie sticky sessions for `ha` |

### Differences from Azure Application Gateway

| Concern | `azure-appgw` (AKS) | `envoy` (this setup) |
| :--- | :--- | :--- |
| GatewayClass | Azure AGIC | `eg` |
| Load balancer | Azure Application Gateway | AKS `LoadBalancer` Service (Envoy pods) |
| Health checks | Azure health probes | `BackendTrafficPolicy` (active health check) |
| Sticky sessions | Azure cookie-based affinity | `BackendTrafficPolicy` (ConsistentHash/Cookie) |
| Azure-specific config | Required | **Not needed** |
| Portability | AKS only | Any Kubernetes distribution |

## Troubleshooting

### No External IP assigned

Envoy Gateway creates a `Service` of type `LoadBalancer` in the `envoy-gateway-system` namespace. On AKS this is provisioned automatically. Check:

```bash
kubectl get svc -n envoy-gateway-system
kubectl describe gateway cloudbees-gateway -n cloudbees-envoy
```

### 503 / No Healthy Upstream

Active health checks are enforced by Envoy. If backends are not yet ready, Envoy will not route traffic until `healthyThreshold` is met. Check pod readiness:

```bash
kubectl get pods -n cloudbees-envoy
kubectl describe backendtrafficpolicy -n cloudbees-envoy
```

### Test with curl

```bash
curl -v -L -k https://gateway-envoy.acaternberg.flow-training.beescloud.com/cjoc/whoAmI/api/json

# Requires controller "ha" to be created first
curl -v -L -k https://gateway-envoy.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json

# Sticky session test
curl -c cookie.txt -v -L -k https://gateway-envoy.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -b cookie.txt -v -L -k https://gateway-envoy.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
```

### Continuous Sticky Session Testing

For continuous monitoring of sticky sessions and controller routing, use the helper script from the root `scripts/` directory:

```bash
# Update the CONTROLLER_URL in the script to your endpoint
../../scripts/testHeaders.sh
```

This script continuously verifies the connection to controller replicas and displays the active replica and cookie information.

## Reference Documentation

| Topic | Documentation Link |
| :--- | :--- |
| **Envoy Gateway Overview** | [envoyproxy.io/docs/gateway](https://gateway.envoyproxy.io/docs/) |
| **BackendTrafficPolicy** | [Envoy Gateway — BackendTrafficPolicy](https://gateway.envoyproxy.io/docs/api/extension_types/#backendtrafficpolicy) |
| **Consistent Hash Load Balancing** | [Envoy LB Policy Docs](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers) |
| **Kubernetes Gateway API** | [Official SIG Docs](https://gateway-api.sigs.k8s.io/) |
| **Envoy Gateway Helm Chart** | [charts.envoyproxy.io](https://charts.envoyproxy.io) |
