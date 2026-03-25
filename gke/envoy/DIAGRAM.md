# Envoy Gateway Architecture & Traffic Flow

This diagram illustrates how external traffic reaches the CloudBees CI Operations Center (`cjoc`) and Managed Controllers (e.g., `ha`) when using **Envoy Gateway** as the ingress controller.

```mermaid
graph TD
    subgraph External
        Client(("External Client"))
    end

    subgraph "Envoy Gateway System (envoy-gateway-system)"
        EGCtrl["Envoy Gateway Controller<br/>(Deployment)"]
        GatewayClass["GatewayClass: eg<br/>(gateway.envoyproxy.io/gatewaycontroller)"]
    end

    subgraph "GKE Cloud (LoadBalancer)"
        LB["GKE LoadBalancer Service<br/>(provisioned by Envoy Gateway)"]
    end

    subgraph "Kubernetes Cluster (cloudbees-envoy namespace)"
        EnvoyProxy["Envoy Proxy Pod(s)<br/>(managed by EG Controller)"]
        Gateway["Gateway: cloudbees-gateway<br/>(HTTPS :443 / TLS Terminate)"]
        TLSSecret["TLS Secret<br/>(acaternberg-cert-selfsigned)"]
        HTTPRoute["HTTPRoute: cloudbees-route<br/>(Path-based routing)"]

        BTP_CJOC["BackendTrafficPolicy: cjoc<br/>(Active Health Check)"]
        BTP_HA["BackendTrafficPolicy: ha<br/>(Active Health Check + Cookie Sticky)"]

        subgraph "Operations Center (cjoc)"
            Svc_CJOC["Service: cjoc"]
            Pod_CJOC["Pod: cjoc-0"]
        end

        subgraph "HA Controller (ha)"
            Svc_HA["Service: ha"]
            Pod_HA["Pod: ha-0 / ha-1"]
        end
    end

    Client -- "HTTPS (443)" --> LB
    LB --> EnvoyProxy
    EGCtrl -- "Manages" --> EnvoyProxy
    EGCtrl -- "Watches" --> GatewayClass
    GatewayClass -- "Implements" --> Gateway
    Gateway -- "Terminates TLS" --> TLSSecret
    Gateway -- "Routes via" --> HTTPRoute
    HTTPRoute -- "/cjoc → " --> Svc_CJOC
    HTTPRoute -- "/ha → " --> Svc_HA
    Svc_CJOC --> Pod_CJOC
    Svc_HA --> Pod_HA

    BTP_CJOC -- "Active Health Check<br/>/cjoc/health/" --> Svc_CJOC
    BTP_HA   -- "Active Health Check<br/>/ha/health/<br/>+ Cookie Consistent Hash" --> Svc_HA

    style EGCtrl    fill:#f9f,stroke:#333,stroke-width:2px
    style EnvoyProxy fill:#f9f,stroke:#333,stroke-width:2px
    style BTP_CJOC  fill:#bbf,stroke:#333,stroke-width:2px
    style BTP_HA    fill:#f96,stroke:#333,stroke-width:2px
    style Pod_CJOC  fill:#dfd,stroke:#333,stroke-width:2px
    style Pod_HA    fill:#dfd,stroke:#333,stroke-width:2px
```

## Component Breakdown

1. **External Client**: Initiates HTTPS requests to `https://gateway.acaternberg.flow-training.beescloud.com/`.
2. **GKE LoadBalancer**: A `Service` of type `LoadBalancer` automatically provisioned by Envoy Gateway. Exposes the Envoy proxy pods externally.
3. **GatewayClass (`eg`)**: Links the Gateway resource to the Envoy Gateway controller (`gateway.envoyproxy.io/gatewaycontroller`). Equivalent to the GKE `gke-l7-regional-external-managed` GatewayClass.
4. **Gateway (`cloudbees-gateway`)**: Defines the HTTPS listener on port 443 with TLS termination using the Kubernetes TLS secret.
5. **HTTPRoute (`cloudbees-route`)**: Path-based routing:
   - `/cjoc/*` → `cjoc` Service
   - `/ha/*` → `ha` Service
6. **BackendTrafficPolicy (cjoc)**: Configures active HTTP health checks probing `/cjoc/health/` on the `cjoc` Service. Equivalent to the GKE `HealthCheckPolicy`.
7. **BackendTrafficPolicy (ha)**: Configures active HTTP health checks on `/ha/health/` **and** cookie-based consistent-hash load balancing (sticky sessions) via `CBCI_SESSION`. This is the combined equivalent of GKE's `HealthCheckPolicy` + `GCPBackendPolicy`.
8. **Envoy Proxy Pods**: The data-plane sidecar pods managed by Envoy Gateway. All routing, health checking, and session-affinity logic is enforced here — no GCP-specific proxy subnet required.

## Key Differences vs. GKE Gateway API

| Concern | GKE Gateway API | Envoy Gateway |
| :--- | :--- | :--- |
| GatewayClass | `gke-l7-regional-external-managed` | `eg` |
| Load balancer | GCP Regional External ALB | GKE Service `type: LoadBalancer` (Envoy pods) |
| Health checks | `HealthCheckPolicy` (networking.gke.io) | `BackendTrafficPolicy` (active health check) |
| Sticky sessions | `GCPBackendPolicy` (GENERATED_COOKIE) | `BackendTrafficPolicy` (ConsistentHash/Cookie) |
| Proxy subnet | GCP proxy-only subnet required | Not needed |
| TLS | Kubernetes TLS secret | Kubernetes TLS secret (same) |
