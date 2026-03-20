# GKE Gateway API Architecture & Traffic Flow

This diagram illustrates how external traffic reaches the CloudBees CI Operations Center (`cjoc`) and Managed Controllers (e.g., `ha`), along with the health check and session affinity configurations.

```mermaid
graph TD
    subgraph External
        Client(("External Client"))
    end

    subgraph "Google Cloud Load Balancing (GKE Gateway)"
        Gateway["Gateway Resource<br/>(Regional External ALB)"]
        HC_CJOC["GCP Health Check: cjoc<br/>(Path: /cjoc/health/)"]
        HC_HA["GCP Health Check: ha<br/>(Path: /ha/health/)"]
        Sticky["GCP Backend Policy<br/>(Sticky Sessions: ha)"]
    end

    subgraph "Kubernetes Cluster (cloudbees-gatewayapi namespace)"
        HTTPRoute["HTTPRoute: cjoc<br/>(Path-based routing)"]
        
        subgraph "Operations Center (cjoc)"
            Svc_CJOC["Service: cjoc"]
            HCP_CJOC["HealthCheckPolicy: cjoc"]
            Pod_CJOC["Pod: cjoc-0"]
        end

        subgraph "HA Controller (ha)"
            Svc_HA["Service: ha"]
            HCP_HA["HealthCheckPolicy: ha"]
            GBP_HA["GCPBackendPolicy: sticky"]
            Pod_HA["Pod: ha-0/ha-1"]
        end
    end

    Client -- "HTTPS (443)" --> Gateway
    Gateway -- "Route Match" --> HTTPRoute
    HTTPRoute -- "/cjoc" --> Svc_CJOC
    HTTPRoute -- "/ha" --> Svc_HA

    Svc_CJOC -- "Direct Pod Access" --> Pod_CJOC
    Svc_HA -- "Direct Pod Access" --> Pod_HA

    HCP_CJOC -- "Configures" --> Svc_CJOC
    HCP_HA -- "Configures" --> Svc_HA
    GBP_HA -- "Enables Stickiness" --> Svc_HA

    HC_CJOC -- "Probe (port 8080)" --> Pod_CJOC
    HC_HA -- "Probe (port 8080)" --> Pod_HA
    
    Gateway -.-> Sticky
    Sticky -.-> Svc_HA

    style Gateway fill:#f9f,stroke:#333,stroke-width:2px
    style HCP_CJOC fill:#bbf,stroke:#333,stroke-width:2px
    style HCP_HA fill:#bbf,stroke:#333,stroke-width:2px
    style GBP_HA fill:#f96,stroke:#333,stroke-width:2px
    style Pod_CJOC fill:#dfd,stroke:#333,stroke-width:2px
    style Pod_HA fill:#dfd,stroke:#333,stroke-width:2px
```

## Component Breakdown

1. External Client: Initiates requests to `https://gateway.acaternberg.flow-training.beescloud.com/`.
2. GKE Gateway: Provisions a Regional External Application Load Balancer. It handles TLS termination and backend service association.
3. HTTPRoute: Defines path-based routing for both the Operations Center (`/cjoc`) and Managed Controllers (`/ha`).
4. HealthCheckPolicy: Overrides default GCP health checks.
    - cjoc: Probes `/cjoc/health/` on port 8080.
    - ha: Probes `/ha/health/` on port 8080.
5. GCPBackendPolicy (Sticky Sessions): Configured for the `ha` controller to enable **Generated Cookie** session affinity with a 1-hour TTL and 60-second connection draining. This is critical for High Availability (HA) controllers where users must remain on the same pod during a session.
6. Services (cjoc, ha): Standard Kubernetes Services configured with Network Endpoint Groups (NEGs) for direct L7-to-Pod load balancing.
7. Pods: The actual application containers. Managed Controllers use NEGs to ensure the Load Balancer can route directly to the correct instance.
