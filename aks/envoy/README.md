# CloudBees CI on AKS with Envoy Gateway

This directory contains resources to deploy CloudBees CI on AKS using **Envoy Gateway**, a cloud-agnostic implementation of the Gateway API.

## Overview

Envoy Gateway provides a standardized way to manage ingress across different Kubernetes environments. This setup provides:

- **TLS Termination**: Secured HTTPS access via Kubernetes secrets.
- **Active Health Checks**: Monitoring backends via `BackendTrafficPolicy`.
- **Session Affinity**: Sticky sessions for HA controllers using consistent hashing.

## Prerequisites

- Access to an AKS cluster.
- Completed authentication via [**`aks/auth.sh`**](../auth.sh).
- Root [**`.env`**](../../.env) file configured.

## Getting Started

### 1. Generate SSL Certificates

If you don't have existing certificates, generate self-signed ones:

```bash
# From this directory
../../scripts/generate-ssl-cert.sh
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

On AKS, Envoy Gateway exposes a LoadBalancer service. If it's pending:

- Check the service status: `kubectl get svc -n envoy-gateway-system`
- Describe the Gateway: `kubectl describe gateway -n cloudbees-envoy`

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
