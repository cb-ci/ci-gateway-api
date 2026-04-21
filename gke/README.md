# CloudBees CI on Google Kubernetes Engine (GKE)

This directory contains two approaches for deploying CloudBees CI on Google Kubernetes Engine (GKE) with modern ingress controllers.

## Directory Structure

```
gke/
├── envoy/              # Cloud-agnostic Envoy Gateway implementation
│   ├── README.md
│   ├── DIAGRAM.md
│   ├── install.sh
│   ├── uninstall.sh
│   └── generate-ssl-cert.sh
│
├── google-gw/          # GCP-native Gateway API implementation
│   ├── README.md
│   ├── DIAGRAM.md
│   ├── install.sh
│   └── generate-ssl-cert.sh
│
└── auth.sh             # GCP authentication helper script
```

## Choosing an Approach

### Option 1: Envoy Gateway (`./envoy`)

**Best for:**
- Multi-cloud or hybrid deployments
- Portable configurations across different Kubernetes distributions
- Using standard Gateway API resources (Gateway, HTTPRoute, BackendTrafficPolicy)
- Teams wanting cloud-agnostic infrastructure
- Avoiding GCP-specific dependencies

**Key features:**
- Cloud-agnostic implementation
- Standard Gateway API resources
- No GCP-specific dependencies
- Easy to migrate to other cloud providers
- Active health checks via BackendTrafficPolicy
- Cookie-based sticky sessions via BackendTrafficPolicy
- No proxy-only subnet required

### Option 2: GCP Gateway API (`./google-gw`)

**Best for:**
- GCP-native deployments
- Leveraging GCP's regional external Application Load Balancer
- Integration with GCP networking features (Cloud Armor, IAP, etc.)
- Teams committed to GCP ecosystem
- Production deployments requiring Google's managed load balancer

**Key features:**
- Native GCP integration
- Regional External Application Load Balancer (managed service)
- GCP HealthCheckPolicy (networking.gke.io)
- GCP GCPBackendPolicy for session affinity and connection draining
- Cloud Armor WAF support
- Cloud Logging and Cloud Monitoring integration
- Identity-Aware Proxy (IAP) support
- Google-managed load balancer with high availability

## Quick Start

### 1. Authenticate to the Cluster

The `auth.sh` helper script ensures you are authenticated with GCP and have the correct `kubectl` context:

```bash
chmod +x auth.sh
./auth.sh
```

### 2. Configure Your Environment

Choose your implementation (`envoy` or `google-gw`) and set up your environment variables:

```bash
cd envoy/  # or cd google-gw/
cp .env-template .env
# Edit .env and replace placeholders with your actual values (PROJECT_ID, DOMAIN, etc.)
```

### 3. Generate SSL Certificates

Use the centralized script to generate self-signed certificates for your specified host:

```bash
# From the gke/ directory
../scripts/generate-ssl-cert.sh gateway-envoy.acaternberg.flow-training.beescloud.com
```

### 4. Install CloudBees CI

Run the installation script for your chosen method:

```bash
./install.sh
```

## Comparison

| Feature | Envoy Gateway | GCP Gateway API |
| :--- | :--- | :--- |
| **Portability** | Multi-cloud | GCP only |
| **API Type** | Gateway API (v1) | Gateway API (v1) |
| **Controller** | Envoy Gateway | GKE Gateway Controller |
| **Load Balancer** | GKE LoadBalancer Service (Envoy pods) | Regional External Application LB |
| **GatewayClass** | `eg` | `gke-l7-regional-external-managed` |
| **Health Checks** | BackendTrafficPolicy | HealthCheckPolicy (networking.gke.io) |
| **Sticky Sessions** | BackendTrafficPolicy (ConsistentHash) | GCPBackendPolicy (GENERATED_COOKIE) |
| **TLS Management** | Kubernetes secrets | Kubernetes secrets or Google-managed certs |
| **GCP Integration** | None | Native (Cloud Armor, IAP, Cloud Logging) |
| **Proxy Subnet** | Not required | Proxy-only subnet required |
| **Cost Model** | VM-based (LoadBalancer) | Application Load Balancer pricing |
| **Setup Complexity** | Low | Medium (requires proxy-only subnet) |
| **Network Endpoint Groups** | No | Yes (direct pod routing) |

## 🛠 Prerequisites

### Common Requirements
* `gcloud` CLI installed and authenticated
* `kubectl` CLI tool (with `gke-gcloud-auth-plugin` installed)
* `helm` CLI tool
* A GKE cluster (version 1.24+)
* Valid TLS certificates (or use the provided `../scripts/generate-ssl-cert.sh` script)

### Envoy Gateway Specific
* No additional GCP resources required
* Works with any GKE cluster

### GCP Gateway API Specific
* Gateway API enabled on GKE cluster: `--gateway-api=standard`
* Proxy-only subnet in the region (automatically created by `install.sh`)
* GKE Gateway Controller enabled (automatic with Gateway API)

## Architecture

Both implementations provide:
- **TLS termination** at the ingress layer
- **Path-based routing** for Operations Center (`/cjoc`) and Managed Controllers (e.g., `/ha`)
- **Custom health checks** for CloudBees CI's health endpoints (`/cjoc/health/`, `/ha/health/`)
- **Session affinity** for HA controllers to maintain user sessions on the same pod
- **Connection draining** for graceful pod terminations

See individual DIAGRAM.md files for detailed architecture diagrams.

## Key Differences Explained

### 1. Load Balancer Architecture

**Envoy Gateway:**
- Runs as pods within your GKE cluster
- Exposes via a standard Kubernetes LoadBalancer Service
- Traffic flow: External LB → Envoy Pods → Application Pods

**GCP Gateway API:**
- Uses Google's Regional External Application Load Balancer (managed service)
- Leverages Network Endpoint Groups (NEGs) for direct pod routing
- Traffic flow: Regional ALB → NEGs → Application Pods (direct)

### 2. Health Check Configuration

**Envoy Gateway:**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
spec:
  healthCheck:
    active:
      type: HTTP
      http:
        path: /cjoc/health/
```

**GCP Gateway API:**
```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
spec:
  default:
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /cjoc/health/
```

### 3. Session Affinity

**Envoy Gateway:**
```yaml
loadBalancer:
  type: ConsistentHash
  consistentHash:
    type: Cookie
    cookie:
      name: CBCI_SESSION
```

**GCP Gateway API:**
```yaml
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
spec:
  default:
    sessionAffinity:
      type: GENERATED_COOKIE
      cookieTtlSec: 3600
```

## Troubleshooting

### Common Issues

* **No external IP assigned:**
  * Envoy: Check `kubectl get svc -n envoy-gateway-system`
  * GCP Gateway: Check `kubectl describe gateway -n <namespace>` and GCP Console → Load Balancing
* **503/502 errors:**
  * Check pod readiness: `kubectl get pods -n <namespace>`
  * Envoy: Check `kubectl describe backendtrafficpolicy -n <namespace>`
  * GCP Gateway: Check backend health in GCP Console → Load Balancing → Backend Services
* **GCP Gateway: Proxy-only subnet errors:**
  * Verify subnet exists: `gcloud compute networks subnets list --filter="purpose=REGIONAL_MANAGED_PROXY"`
  * Check subnet is in the correct region
  * Ensure subnet doesn't overlap with existing ranges
* **Certificate issues:**
  * Ensure certificates are valid and properly formatted
  * Check secret exists: `kubectl get secret <cert-name> -n <namespace>`
  * Verify certificate chain is complete

### Stuck "Terminating" Resources

On GKE, if you delete a Gateway or Gateway API CRDs while they are still in use (or if the managed controller is delayed), they can get stuck in a "Terminating" state. This is often due to stuck finalizers. To resolve this:

```bash
# Patch the resource to remove finalizers
kubectl patch gateway <name> -n <namespace> -p '{"metadata":{"finalizers":null}}' --type=merge

# If the CRD itself is stuck
kubectl patch crd gateways.gateway.networking.k8s.io -p '{"metadata":{"finalizers":null}}' --type=merge
```

### Testing Sticky Sessions

For continuous monitoring of sticky sessions and controller routing (particularly important for HA controllers), use the test script:

```bash
cd ../scripts
# Update CONTROLLER_URL in testHeaders.sh to your endpoint
./testHeaders.sh
```

This script verifies connection persistence to controller replicas through the load balancer and displays active replica and cookie information.

## Migration Between Approaches

### From GCP Gateway API to Envoy Gateway

1. Deploy Envoy Gateway setup in parallel
2. Update DNS to point to Envoy Gateway external IP
3. Monitor traffic and validate functionality
4. Decommission GCP Gateway API resources

**Benefits:** Reduced GCP lock-in, lower costs (no Regional ALB), simpler architecture

**Trade-offs:** Loss of GCP-native features (Cloud Armor, IAP), manual health check management

### From Envoy Gateway to GCP Gateway API

1. Enable Gateway API on GKE cluster
2. Create proxy-only subnet
3. Deploy GCP Gateway API setup in parallel
4. Update DNS to point to Regional ALB IP
5. Monitor traffic and validate functionality
6. Decommission Envoy Gateway resources

**Benefits:** GCP-native features, managed load balancer, Cloud Logging integration

**Trade-offs:** Increased costs, GCP lock-in, additional network configuration

## Cost Considerations

### Envoy Gateway
- **VM costs**: LoadBalancer Service provisions GCP Network Load Balancer
- **Compute costs**: Envoy proxy pods consume cluster CPU/memory
- **Simpler pricing**: Standard compute + load balancer forwarding rules

### GCP Gateway API
- **Application Load Balancer**: Charged per hour + per GB processed
- **Forwarding rules**: Regional external forwarding rule costs
- **Health checks**: Included in ALB pricing
- **Potential savings**: Direct pod routing (NEGs) can reduce data transfer

**Estimate:** GCP Gateway API typically 20-40% more expensive than Envoy Gateway for moderate traffic volumes.

## Authentication Helper

The `auth.sh` script provides a quick way to authenticate with GCP and configure kubectl:

```bash
./auth.sh
```

This script handles:
- GCP authentication
- Project selection
- Kubectl context configuration
- Cluster credentials retrieval

## Reference Documentation

| Topic | Link |
| :--- | :--- |
| **Envoy Gateway** | [envoyproxy.io/docs/gateway](https://gateway.envoyproxy.io/docs/) |
| **Gateway API** | [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/) |
| **GKE Gateway API** | [GCP Docs](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api) |
| **GKE Gateway Controller** | [Configuration Examples](https://cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways) |
| **GCPBackendPolicy** | [Backend Policy Docs](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources#gcpbackendpolicy) |
| **HealthCheckPolicy** | [Health Check Docs](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources#healthcheckpolicy) |
| **CloudBees CI** | [CloudBees Documentation](https://docs.cloudbees.com/docs/cloudbees-ci/latest/) |

## Next Steps

1. **Choose your approach** based on your requirements (portability vs. GCP-native features)
2. **Review the specific README** in the chosen directory for detailed setup instructions
3. **Generate certificates** using the provided scripts
4. **Run the installation** and verify deployment
5. **Configure DNS** to point to the external IP
6. **Test thoroughly** using curl and the `testHeaders.sh` script
7. **Monitor** using kubectl and GCP Console (for GCP Gateway API)
