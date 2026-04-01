# CloudBees CI on Azure Kubernetes Service (AKS)

This directory contains two approaches for deploying CloudBees CI on Azure Kubernetes Service (AKS) with modern ingress controllers.

## Directory Structure

```
aks/
├── envoy/              # Cloud-agnostic Envoy Gateway implementation
│   ├── README.md
│   ├── DIAGRAM.md
│   ├── install.sh
│   └── uninstall.sh
│
└── azure-appgw/        # Azure-native Application Gateway Ingress Controller
    ├── README.md
    ├── DIAGRAM.md
    └── install.sh
```

**Note:** SSL certificate generation script has been centralized to `../scripts/generate-ssl-cert.sh`

## Choosing an Approach

### Option 1: Envoy Gateway (`./envoy`)

**Best for:**
- Multi-cloud or hybrid deployments
- Portable configurations across different Kubernetes distributions
- Using standard Gateway API resources (Gateway, HTTPRoute, BackendTrafficPolicy)
- Teams wanting cloud-agnostic infrastructure

**Key features:**
- Cloud-agnostic implementation
- Standard Gateway API resources
- No Azure-specific dependencies
- Easy to migrate to other cloud providers
- Active health checks via BackendTrafficPolicy
- Cookie-based sticky sessions via BackendTrafficPolicy

### Option 2: Azure Application Gateway (`./azure-appgw`)

**Best for:**
- Azure-native deployments
- Leveraging existing Azure Application Gateway instances
- Integration with Azure networking features (WAF, NSG, etc.)
- Teams committed to Azure ecosystem

**Key features:**
- Native Azure integration
- Azure Application Gateway managed service
- WAF (Web Application Firewall) support
- Azure Monitor integration
- Azure Key Vault for certificate management
- Traditional Ingress resources with Azure annotations

## Quick Start

### Envoy Gateway (Cloud-Agnostic)

```bash
# Generate SSL certificates
CJOC_HOST=gateway-envoy.acaternberg.flow-training.beescloud.com ../scripts/generate-ssl-cert.sh
# Install
cd envoy
./install.sh
```

### Azure Application Gateway (Azure-Native)

```bash
# Generate SSL certificates
CJOC_HOST=gateway-appgw.acaternberg.flow-training.beescloud.com ../scripts/generate-ssl-cert.sh
# Install
cd azure-appgw
./install.sh
```

## Comparison

| Feature | Envoy Gateway | Azure Application Gateway |
| :--- | :--- | :--- |
| **Portability** | Multi-cloud | Azure only |
| **API Type** | Gateway API (v1) | Ingress (v1) |
| **Controller** | Envoy Gateway | Azure AGIC |
| **Load Balancer** | AKS LoadBalancer Service | Azure Application Gateway |
| **Health Checks** | BackendTrafficPolicy | Azure health probe annotations |
| **Sticky Sessions** | BackendTrafficPolicy | Cookie-based affinity annotation |
| **TLS Management** | Kubernetes secrets | Kubernetes secrets or Azure Key Vault |
| **Azure Integration** | None | Native (WAF, NSG, Monitor, etc.) |
| **Cost Model** | VM-based (LoadBalancer) | Gateway-based (Application Gateway pricing) |
| **Setup Complexity** | Low-Medium | Medium-High (requires Application Gateway) |

## Prerequisites

### Common Requirements
- Azure CLI (`az`) installed and authenticated
- `kubectl` CLI tool
- `helm` CLI tool
- An AKS cluster (version 1.24+)
- Valid TLS certificates (or use the provided `../scripts/generate-ssl-cert.sh` script)

### Envoy Gateway Specific
- No additional Azure resources required
- Works with any AKS cluster

### Azure Application Gateway Specific
- Azure Application Gateway provisioned (or AGIC addon enabled)
- AGIC installed (either as addon or Helm chart)
- Proper Azure permissions to manage Application Gateway resources

## Architecture

Both implementations provide:
- **TLS termination** at the ingress layer
- **Path-based routing** for Operations Center (`/cjoc`) and Managed Controllers (e.g., `/ha`)
- **Custom health checks** for CloudBees CI's health endpoints
- **Session affinity** for HA controllers to maintain user sessions on the same pod

See individual DIAGRAM.md files for detailed architecture diagrams.

## Troubleshooting

### Common Issues

**No external IP assigned:**
- Envoy: Check `kubectl get svc -n envoy-gateway-system`
- AGIC: Check `kubectl get ingress -n cloudbees-appgw` and Azure Portal

**503/502 errors:**
- Check pod readiness: `kubectl get pods -n <namespace>`
- Verify health check configurations
- Check backend health in Azure Portal (AGIC) or `kubectl describe backendtrafficpolicy` (Envoy)

**Certificate issues:**
- Ensure certificates are valid and properly formatted
- Check secret exists: `kubectl get secret <cert-name> -n <namespace>`

### Testing Sticky Sessions

For continuous monitoring of sticky sessions and controller routing (particularly important for HA controllers), use the test script:

```bash
cd ../scripts
# Update CONTROLLER_URL in testHeaders.sh to your endpoint
./testHeaders.sh
```

This script verifies connection persistence to controller replicas through the load balancer and displays active replica and cookie information.

## Reference Documentation

| Topic | Link |
| :--- | :--- |
| **Envoy Gateway** | [envoyproxy.io/docs/gateway](https://gateway.envoyproxy.io/docs/) |
| **Gateway API** | [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/) |
| **Azure AGIC** | [Microsoft Docs](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview) |
| **AKS Networking** | [AKS Network Concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-network) |
| **CloudBees CI** | [CloudBees Documentation](https://docs.cloudbees.com/docs/cloudbees-ci/latest/) |
