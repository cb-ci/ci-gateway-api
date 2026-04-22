# CloudBees CI on Azure Kubernetes Service (AKS)

This directory contains implementations for deploying CloudBees CI on AKS using modern ingress controllers. We provide both a cloud-agnostic Envoy Gateway approach and an Azure-native Application Gateway (AGIC) approach.

## Choosing an Approach

| Feature | Envoy Gateway (`./envoy`) | Azure Application Gateway (`./azure-appgw`) |
| :--- | :--- | :--- |
| **Stability** | Mature OSS Component | Testing in progress |
| **Portability** | High (Multi-cloud) | Low (Azure only) |
| **Load Balancer** | In-cluster Envoy Proxies | Azure Application Gateway |
| **Networking** | Standard AKS Networking | Native Azure Integration |
| **Cost** | Included in cluster resources | Application Gateway pricing |

## Getting Started

### 1. Authenticate to the Cluster

The `auth.sh` helper script ensures you are authenticated with Azure and have the correct `kubectl` context. It sources the global configuration from the root `.env`.

```bash
chmod +x auth.sh
./auth.sh
```

### 2. Implementation Setup

Choose your implementation and navigate to its directory:

```bash
cd envoy/        # For Envoy Gateway
# OR
cd azure-appgw/  # For Azure Application Gateway
```

### 3. Deployment

Run the installation script. It will handle CRD management, namespace creation, TLS secrets, and the CloudBees CI Helm chart.

```bash
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
