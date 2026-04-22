# CloudBees CI on GKE with Envoy Gateway

This directory contains resources to deploy CloudBees CI on GKE using **Envoy Gateway**, a cloud-agnostic implementation of the Gateway API.

## Overview

By using Envoy Gateway, you can use the same Gateway API resources (Gateway, HTTPRoute) across any Kubernetes distribution. This setup provides:

- **TLS Termination**: Secured HTTPS access via Kubernetes secrets.
- **Active Health Checks**: Monitoring backends via `BackendTrafficPolicy`.
- **Session Affinity**: Sticky sessions for HA controllers using consistent hashing.

## Prerequisites

- Access to a GKE cluster.
- Completed authentication via [**`gke/auth.sh`**](../auth.sh).
- Root [**`.env`**](../../.env) file configured.

## Getting Started

### 1. Generate SSL Certificates

If you don't have existing certificates, generate self-signed ones:

```bash
# From this directory
../../scripts/generate-ssl-cert.sh
```

### 2. Installation

Run the installation script to deploy Envoy Gateway and CloudBees CI:

```bash
chmod +x install.sh
./install.sh
```

### 3. Verification

Retrieve the initial admin password and visit the URL provided at the end of the installation script:

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

### Differences from GKE Gateway API

| Concern | `google-gw` (GKE) | `envoy` (this setup) |
| :--- | :--- | :--- |
| GatewayClass | `gke-l7-regional-external-managed` | `eg` |
| Load balancer | GCP Regional External ALB | GKE `LoadBalancer` Service (Envoy pods) |
| Health checks | `HealthCheckPolicy` (networking.gke.io) | `BackendTrafficPolicy` (active health check) |
| Sticky sessions | `GCPBackendPolicy` (GENERATED_COOKIE) | `BackendTrafficPolicy` (ConsistentHash/Cookie) |
| Proxy subnet | GCP proxy-only subnet required | **Not needed** |
| Portability | GKE only | Any Kubernetes distribution |

## Troubleshooting

### No External IP assigned

On GKE, the LoadBalancer service is provisioned automatically. If it's pending:

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

## Reference Documentation

| Topic | Documentation Link |
| :--- | :--- |
| **Envoy Gateway Overview** | [envoyproxy.io/docs/gateway](https://gateway.envoyproxy.io/docs/) |
| **BackendTrafficPolicy** | [Envoy Gateway — BackendTrafficPolicy](https://gateway.envoyproxy.io/docs/api/extension_types/#backendtrafficpolicy) |
| **Consistent Hash Load Balancing** | [Envoy LB Policy Docs](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers) |
| **Kubernetes Gateway API** | [Official SIG Docs](https://gateway-api.sigs.k8s.io/) |
| **Envoy Gateway Helm Chart** | [charts.envoyproxy.io](https://charts.envoyproxy.io) |
