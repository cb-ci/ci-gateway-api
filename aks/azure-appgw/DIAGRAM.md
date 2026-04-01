# Azure Application Gateway Architecture & Traffic Flow

This diagram illustrates how external traffic reaches the CloudBees CI Operations Center (`cjoc`) and Managed Controllers (e.g., `ha`) when using **Azure Application Gateway Ingress Controller (AGIC)**.

```mermaid
graph TD
    subgraph External
        Client(("External Client"))
    end

    subgraph "Azure Application Gateway"
        AppGW["Azure Application Gateway<br/>(Regional L7 Load Balancer)"]
        HealthProbe_CJOC["Health Probe: cjoc<br/>(Path: /cjoc/health/)"]
        HealthProbe_HA["Health Probe: ha<br/>(Path: /ha/health/)"]
        SessionAffinity["Cookie-Based Affinity<br/>(Sticky Sessions)"]
    end

    subgraph "AGIC Controller"
        AGIC["AGIC Pod<br/>(Watches Ingress resources)"]
    end

    subgraph "Kubernetes Cluster (cloudbees-appgw namespace)"
        Ingress["Ingress: cloudbees-ingress<br/>(Path-based routing)"]

        subgraph "Operations Center (cjoc)"
            Svc_CJOC["Service: cjoc"]
            Pod_CJOC["Pod: cjoc-0"]
        end

        subgraph "HA Controller (ha)"
            Svc_HA["Service: ha"]
            Pod_HA["Pod: ha-0 / ha-1"]
        end
    end

    Client -- "HTTPS (443)" --> AppGW
    AppGW -- "Route Match" --> Ingress
    AGIC -- "Configures" --> AppGW
    AGIC -- "Watches" --> Ingress

    Ingress -- "/cjoc" --> Svc_CJOC
    Ingress -- "/ha" --> Svc_HA

    Svc_CJOC --> Pod_CJOC
    Svc_HA --> Pod_HA

    HealthProbe_CJOC -- "Probe (port 8080)" --> Pod_CJOC
    HealthProbe_HA -- "Probe (port 8080)" --> Pod_HA

    SessionAffinity -.-> Svc_HA

    style AppGW fill:#f9f,stroke:#333,stroke-width:2px
    style AGIC fill:#f96,stroke:#333,stroke-width:2px
    style HealthProbe_CJOC fill:#bbf,stroke:#333,stroke-width:2px
    style HealthProbe_HA fill:#bbf,stroke:#333,stroke-width:2px
    style SessionAffinity fill:#f96,stroke:#333,stroke-width:2px
    style Pod_CJOC fill:#dfd,stroke:#333,stroke-width:2px
    style Pod_HA fill:#dfd,stroke:#333,stroke-width:2px
```

## Component Breakdown

1. **External Client**: Initiates HTTPS requests to `https://gateway-appgw.acaternberg.flow-training.beescloud.com/`.
2. **Azure Application Gateway**: A regional Layer 7 load balancer that handles TLS termination, path-based routing, and health probing. Provisioned in Azure as a managed service.
3. **AGIC (Application Gateway Ingress Controller)**: A Kubernetes controller that watches Ingress resources and automatically configures the Azure Application Gateway based on annotations and rules.
4. **Ingress**: Standard Kubernetes Ingress resource with Azure-specific annotations defining:
   - Path-based routing for `/cjoc` and `/ha`
   - Custom health probe paths
   - Cookie-based session affinity
   - SSL settings
5. **Health Probes**: Azure Application Gateway health probes configured via annotations:
   - **cjoc**: Probes `/cjoc/health/` on port 8080
   - **ha**: Probes `/ha/health/` on port 8080
6. **Session Affinity**: Cookie-based sticky sessions enabled for the `ha` controller to ensure users remain on the same pod during their session. Critical for High Availability (HA) controllers.
7. **Services (cjoc, ha)**: Standard Kubernetes ClusterIP Services that expose the CloudBees CI pods.
8. **Pods**: The actual CloudBees CI application containers.

## Key Differences vs. Envoy Gateway

| Concern | Envoy Gateway | Azure Application Gateway |
| :--- | :--- | :--- |
| Controller | Envoy Gateway Controller | Azure AGIC |
| Load balancer | AKS Service LoadBalancer (Envoy pods) | Azure Application Gateway (managed service) |
| Health checks | `BackendTrafficPolicy` (CRD) | Azure health probe annotations |
| Sticky sessions | `BackendTrafficPolicy` (CRD) | Cookie-based affinity annotation |
| Configuration | Gateway API resources (Gateway, HTTPRoute) | Ingress resources with annotations |
| Azure integration | None | Native Azure networking (WAF, NSG, etc.) |
| TLS | Kubernetes secret | Kubernetes secret or Azure Key Vault |
