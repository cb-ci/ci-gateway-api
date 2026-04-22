# CloudBees CI on AKS with Azure Application Gateway

This directory contains resources to deploy CloudBees CI on AKS using the native **Azure Application Gateway Ingress Controller (AGIC)**.

## Overview

AGIC provides a direct integration between Kubernetes ingress and Azure's managed Application Gateway, enabling L7 load balancing. This setup provides:

- **Managed Infrastructure**: Offloads load balancing to a dedicated Azure service.
- **Enterprise Features**: Supports WAF and native Azure Monitor integration.
- **Cookie Affinity**: Native Azure cookie-based session affinity for controllers.

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

Run the installation script to deploy AGIC and CloudBees CI:

```bash
chmod +x install.sh
./install.sh
```

### 3. Accessing Operations Center

Once the deployment is complete, retrieve the initial admin password:

```bash
kubectl exec -ti cjoc-0 -n cloudbees-appgw -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Visit: `https://gateway-appgw.acaternberg.flow-training.beescloud.com/cjoc`

## Architecture

For a detailed look at the traffic flow and component relationships, see [DIAGRAM.md](./DIAGRAM.md).

![AGIC](https://learn.microsoft.com/en-us/azure/application-gateway/media/application-gateway-ingress-controller-overview/architecture.png)

### Key Resources

| Resource | Kind | Purpose |
| :--- | :--- | :--- |
| `cloudbees-ingress` | `Ingress` | Path-based routing with Azure Application Gateway |
| Azure health probes | Annotation | Custom health check paths (`/cjoc/health/`, `/ha/health/`) |
| Session affinity | Annotation | Cookie-based sticky sessions for HA controllers |

### Azure-Specific Annotations

The Ingress resources use Azure-specific annotations to configure:

- **Health probes**: `appgw.ingress.kubernetes.io/health-probe-*` for custom health paths
- **Session affinity**: `appgw.ingress.kubernetes.io/cookie-based-affinity: "Enabled"`
- **Connection draining**: `appgw.ingress.kubernetes.io/connection-draining-timeout: "60"`
- **SSL**: `appgw.ingress.kubernetes.io/ssl-redirect: "true"`

### Differences from Envoy Gateway

| Concern | `envoy` (cloud-agnostic) | `azure-appgw` (this setup) |
| :--- | :--- | :--- |
| Controller | Envoy Gateway | Azure AGIC |
| Load balancer | AKS Service LoadBalancer (Envoy pods) | Azure Application Gateway |
| Health checks | `BackendTrafficPolicy` | Azure health probe annotations |
| Sticky sessions | `BackendTrafficPolicy` | Azure cookie-based affinity annotation |
| Azure integration | None | Native Azure networking integration |
| Portability | Any Kubernetes distribution | AKS only |

## Troubleshooting

### No Public IP assigned

The Application Gateway may take several minutes to provision. Check:

```bash
kubectl get ingress -n cloudbees-appgw
az network application-gateway show --resource-group <rg> --name <appgw-name>
```

### 502 Bad Gateway

If you see 502 errors, check:

- Backend health status in Azure Portal
- Pod readiness: `kubectl get pods -n cloudbees-appgw`
- Health probe configuration in Application Gateway

### Test with curl

```bash
curl -v -L -k https://gateway-appgw.acaternberg.flow-training.beescloud.com/cjoc/whoAmI/api/json

# Requires controller "ha" to be created first
curl -v -L -k https://gateway-appgw.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json

# Sticky session test
curl -c cookie.txt -v -L -k https://gateway-appgw.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
curl -b cookie.txt -v -L -k https://gateway-appgw.acaternberg.flow-training.beescloud.com/ha/whoAmI/api/json
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
| **Azure AGIC Overview** | [Microsoft Docs](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) |
| **AGIC Annotations** | [Ingress Annotations Reference](https://azure.github.io/application-gateway-kubernetes-ingress/annotations/) |
| **Application Gateway Features** | [Azure Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/overview) |
| **AKS Integration** | [Enable AGIC on AKS](https://learn.microsoft.com/en-us/azure/application-gateway/tutorial-ingress-controller-add-on-existing) |
