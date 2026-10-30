# CloudBees CI MCP Router documentation

Collected 2026-10-29 from <https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/> and its sub-pages.
Page text was retrieved through the CloudBees docs search index (librarian-doc), which serves docs.beescloud.com content for the same paths; it was not scraped from docs.cloudbees.com directly. Page bodies are unmodified, but relative links are left as-is.

Helm values in "Enable OAuth with Helm" were cross-checked against the `cloudbees-core` chart on Artifact Hub (<https://artifacthub.io/packages/helm/cloudbees/cloudbees-core>), chart version 3.38435.0+980594e799d5 (CloudBees CI 2.580.2.38434). The `McpRouter.privateKeyJwt`, `McpRouter.extraEnv`, `McpRouter.ocInternalUrl`, and `McpRouter.javaOpts` entries were expanded from that chart's parameter table.

## Add mcp server

```
claude mcp remove ci-mcp-router
claude mcp add --transport http --client-id ci-mcp-client \
--callback-port 8123 ci-mcp-router https://ci.acaternberg.aws.ps.beescloud.com/mcp-router/mcp

```

## Architecture

The diagrams below summarize the relationships described in the pages that follow. They are an overview, not part of the upstream documentation.

### Components (generic)

```mermaid
flowchart LR
    subgraph Clients["MCP agents"]
        A1["Claude Code"]
        A2["GitHub Copilot"]
        A3["Goose"]
        A4["Kiro"]
    end

    subgraph Deploy["Docker or Kubernetes (Helm: McpRouter.enabled)"]
        R["CloudBees CI MCP Router<br/>/mcp endpoint<br/>rate limiting (optional)"]
    end

    subgraph OCsub["Operations center (cjoc)"]
        OC["Operations center"]
        AS["OAuth Authorization Server plugin<br/>discovery endpoints, token exchange"]
    end

    subgraph Ctrls["Controllers"]
        C1["Controller A<br/>MCP Server plugin<br/>OAuth Resource Server plugin"]
        C2["Controller B<br/>MCP Server plugin<br/>OAuth Resource Server plugin"]
    end

    A1 & A2 & A3 & A4 -->|"MCP over HTTP<br/>OAuth bearer or API token"| R
    A1 & A2 & A3 & A4 -.->|"OAuth discovery, sign-in, consent"| AS
    R -->|"list controllers (cached)"| OC
    R -->|"token exchange<br/>projected SA token (aud: cjoc)<br/>or private_key_jwt"| AS
    R -->|"tool calls with exchanged<br/>or forwarded credentials"| C1
    R -->|"tool calls with exchanged<br/>or forwarded credentials"| C2
    OC --- C1
    OC --- C2
```

### OAuth flow (generic)

```mermaid
sequenceDiagram
    autonumber
    participant Agent as MCP agent
    participant AS as Authorization server<br/>(operations center)
    participant R as MCP Router
    participant C as Controller<br/>(MCP Server + Resource Server plugins)

    Agent->>R: Connect to /mcp
    R-->>Agent: OAuth required (discovery endpoints)
    Agent->>AS: Authorize (user signs in, approves client)
    AS-->>Agent: Access token (aud: router)
    Agent->>R: Tool call with bearer token
    R->>AS: Token exchange (projected SA token or private_key_jwt)
    AS-->>R: Controller-scoped token (FLEET: one token, PER_TARGET: one per controller)
    R->>C: Forward request with exchanged token
    C-->>R: Result
    R-->>Agent: Result
```

In `AUTO` upstream mode, the router exchanges OAuth bearer tokens and forwards any other `Authorization` header (Basic or API token) unchanged. `OAUTH_ONLY` rejects anything but a bearer token.

## This environment

Derived from the CasC exports in `casc/export/cjoc-export` and `casc/export/controller-export` (exported 2026-10-29), `eks/eksctl/05-installCloudBees.sh`, and router behavior observed on 2026-10-29. Secrets (encrypted client secrets, GitHub token, license key) are in those exports but are deliberately not reproduced here. Do not commit the exports as-is.

### Topology

```mermaid
flowchart LR
    Agent["Claude Code<br/>client-id ci-mcp-client (PKCE)"]

    subgraph EKS["EKS cluster, namespace cbci"]
        GW["Gateway API: cbci-gateway<br/>ci.acaternberg.aws.ps.beescloud.com"]
        R["MCP Router<br/>upstreamMode AUTO<br/>500m CPU, 1Gi"]

        subgraph OCS["Operations center /cjoc"]
            OC["cjoc<br/>RBAC: cloudBeesRoleBasedAccessControl<br/>plugins: mcp-server, cloudbees-oauth-server,<br/>cloudbees-oauth-resource, oauth-credentials"]
            AS["OAuth server /cjoc/oauth-server<br/>issuer, JWKS, token exchange"]
        end

        subgraph ON["Controllers online (MCP reachable)"]
            C1["controller1"]
            C3["controller3"]
            W["workshop"]
            F1["folder-dev1-controllers/folder-controller1"]
            F2["folder-dev1-controllers/folder-controller2"]
        end

        subgraph OFF["Controllers offline or deprovisioned"]
            C2["controller2 (DEPROVISIONED)"]
            H["hahs, plugable-storage,<br/>plugins-casc-uc, testnodegroup (CREATED, offline)"]
        end
    end

    Agent -->|"HTTPS /mcp-router/mcp<br/>OAuth bearer"| GW
    Agent -.->|"discovery, sign-in, consent"| AS
    GW --> R
    GW --> OC
    OC --- AS
    R -->|"GET controller list<br/>/cjoc/mcp-server/stateless"| OC
    R -->|"token exchange<br/>client cloudbees-mcp-router"| AS
    R -->|"/NAME/mcp-server/stateless<br/>exchanged token"| ON
    R -.->|"unreachable"| OFF
```

The router sees the request at `/mcp`; the gateway publishes it at `https://<CJOC_HOST_NAME>/mcp-router/mcp` (per the install script). Each controller exposes MCP at `https://<CJOC_HOST_NAME>/<controller-path>/mcp-server/stateless`.

### Token exchange sequence

```mermaid
sequenceDiagram
    autonumber
    participant A as Claude Code
    participant R as MCP Router
    participant AS as OAuth server (cjoc)
    participant OC as cjoc mcp-server
    participant C as Controller mcp-server

    A->>R: POST /mcp (OAuth bearer, aud: router)
    R->>AS: Exchange 1, requested aud cjoc
    AS-->>R: OC-scoped token
    R->>OC: List controllers (cached, default 1H)
    OC-->>R: names, endpoints, status online/offline
    R->>AS: Exchange 2, requested aud = every controller URL
    Note over AS: Fails with invalid_target if any aud is missing<br/>from the global OR the per-client allow-list
    AS-->>R: Controller-scoped token
    R->>C: Tool call (getJobs, triggerBuild, ...)
    C-->>R: Result
    R-->>A: Result
```

### Install

`eks/eksctl/05-installCloudBees.sh` installs `cloudbees/cloudbees-core` (release `cloudbees-core-envoy`) with the Gateway enabled (`Gateway.Name`, `Gateway.SectionName=https`, namespace `cbci`) and the OC pinned to the `workload=controller` node group. MCP is opt-in:

```bash
MCP_ENABLED=true ./05-installCloudBees.sh
```

which adds:

| Helm value | Setting |
| --- | --- |
| `OperationsCenter.OAuthServer.Enabled` | `true` |
| `McpRouter.enabled` | `true` |
| `McpRouter.upstreamMode` | `${MCP_UPSTREAM_MODE:-AUTO}` |
| `McpRouter.resources.requests` | `cpu=500m`, `memory=1Gi` |
| `McpRouter.extraEnv` (optional) | `MCP_RATE_LIMIT_ENABLED`, `_PERMITS`, `_WINDOW`; `MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL` (from `MCP_CONTROLLERS_CACHE_TTL`) |

### Operations center bundle (`cjoc-export`, bundle id `jenkins`)

| Area | Setting |
| --- | --- |
| Plugins | `mcp-server`, `cloudbees-oauth-server`, `cloudbees-oauth-resource`, `oauth-credentials` (among the OC plugins) |
| OAuth server | issuer `https://<domain>/cjoc/oauth-server`; `internalJwksUrl: http://cjoc/cjoc/oauth-server/jwks`; access token TTL 600s; exchanged token TTL 300s; DCR disabled; `autoApproveSeededClients: true`; `enforceTrustedIssuer: false` |
| OAuth resource server | `trustedIssuer` = the issuer above; `filterMode: AUTO`; `protectedPaths: /mcp-server/*` |
| Client `cloudbees-mcp-router` | confidential, `grantTokenExchange: true`, `CLIENT_SECRET_BASIC`, `audience: https://<domain>/mcp-router`, per-client `allowedAudiences` (see below) |
| Client `ci-mcp-client` | public, auth-code + refresh, PKCE required, redirect URIs `http://127.0.0.1/callback`, `http://[::1]/callback`, `http://localhost/callback` |
| Bundle source | `bundleStorageService` SCM bundle `controllers`, `main` branch of the `cb-ci/ci-gateway-api` GitHub repo, polling every 60s; `automaticReload` and `automaticRestart` on |
| Provisioning | Kubernetes cluster endpoint `default`, Gateway exposure `cbci-gateway` in `cbci`, WebSocket, `gp2` storage |
| Items | 10 managed controllers (below); cluster operations `cluster-op-backup-controllers`, `cluster-op-hello`, `cluster-op-test`, `cluster-op-upgrade-controllers`, `clusterop-upgrade-controller-by-op`, and in `folder-dev1-controllers`: `cluster-op-backups`, `cluster-op-reprovsion`; folder `department` |

### Controller bundle (`controller-export`, bundle id `controller1`)

| Area | Setting |
| --- | --- |
| Plugins | `mcp-server`, `cloudbees-oauth-resource`, `cloudbees-oauth-server`, plus backup (`infradna-backup`), `github-branch-source`, `workflow-aggregator` and others |
| OAuth resource server | `trustedIssuer: https://<domain>/cjoc/oauth-server`; `jwksUrl: http://cjoc/cjoc/oauth-server/jwks` (in-cluster, avoids hairpin NAT); `filterMode: AUTO`; `protectedPaths: /mcp-server/*`; clock skew 60s |
| Items | `backup` and `restore` Backup projects (S3 store), folder `developers` |

The controller export also contains an `oauthAuthorizationServer` block and the two OAuth client credentials. They are export artifacts of having the OAuth server plugin installed. The authoritative server and clients live on the OC; do not rely on them on controllers.

### Allowed audiences (the part that breaks token exchange)

There are two independent allow-lists on the OC, and an exchange succeeds only if every requested audience is in both:

1. **Global**: `security.oauthAuthorizationServer.allowedAudiences`. The 2026-10-29 export lists only `https://<domain>/cjoc`.
2. **Per client**: `allowedAudiences` on `cloudbees-mcp-router`. In the exports it lists `controller1`, `controller2`, `controller3`, `folder-dev1-controllers-folder-controller1`, `folder-dev1-controllers-folder-controller2`, `hahs`, `plugins-casc-uc`, `plugable-storage`, `testnodegroup`, `workshop`, and `cjoc` (all as `https://<domain>/<name>`).

The router requests every controller audience at once (exchange 2 above). If one is missing or the controller has been removed from the lists inconsistently, the whole call fails. Keep both lists in sync with the controller set, and keep the global list in CasC so a bundle reload does not revert a UI edit.

### Controller status when this was written

| Controller | Status | State |
| --- | --- | --- |
| controller1, controller3, workshop | online | APPROVED |
| folder-dev1-controllers/folder-controller1, folder-controller2 | online | APPROVED |
| controller2 | offline | DEPROVISIONED |
| hahs, plugable-storage, plugins-casc-uc, testnodegroup | offline | CREATED |

Offline controllers return empty results through the router, and an unfiltered call can time out waiting on them. Use `controllerNames` to target online controllers.

### Connect Claude Code

```bash
claude mcp add ci-mcp-router https://<domain>/mcp-router/mcp --transport http --client-id ci-mcp-client
```

Then run `/mcp`, select `ci-mcp-router`, and approve in the browser.

### Troubleshooting seen here

| Symptom | Cause | Fix |
| --- | --- | --- |
| `/mcp` fails with HTTP 504, router log `token-exchange failed ... invalid_target ... allowedAudiences for client_id=cloudbees-mcp-router` | `https://<domain>/cjoc` missing from the per-client list | Add it to the `cloudbees-mcp-router` client |
| Tools return `audience not in configured allow-list: .../controller2` | Controller audiences missing from the global `allowedAudiences` | Add all controller audiences to the global list, in the CasC bundle as well as the UI |
| Router warns `/cjoc/mcp-server/stateless returned 404`, `listControllers` unavailable | `mcp-server` plugin not installed on the OC at router start | Install the plugin, then reconnect with `/mcp` (the router retries per session) |
| Empty job lists, or unfiltered calls time out | Target controllers offline, deprovisioned or hibernating | Start them, or pass `controllerNames` |
| `getJobs` on the OC (`operations-center`) returns `[]` | OC MCP tools cover topology (`listControllers`), not job listing | Use the CJOC UI or REST API for OC items and cluster operations |
| Router logs `Invalid MCP protocol header: 2026-07-28` (HTTP 400) then continues | Client sends a newer protocol version than the router's Quarkus MCP extension supports | Harmless fallback; update the router image when available |

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router -->

# Install the CloudBees CI MCP Router

Install the CloudBees CI MCP Router
===================================

To install the CloudBees CI MCP Router, first install the [MCP Server plugin](/plugins/ci/mcp-server) on your controllers, and then deploy the CloudBees CI MCP Router as a Docker container or in a Kubernetes cluster.

* If you already deploy CloudBees CI on Kubernetes with the `cloudbees-core` Helm chart and plan to use OAuth, you can deploy and configure the CloudBees CI MCP Router using Helm without following the manual deployment steps on this page. For more information, refer to [Enable OAuth with Helm](/docs/cloudbees-ci/latest/mcp-router/oauth#enable-helm).

* To protect the CloudBees CI MCP Router from request floods and runaway agent loops, refer to [Enable rate limiting for the CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/rate-limiting).

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have the following:

* CloudBees CI version 2.541.2.35785 or later.

* The [MCP Server plugin](/plugins/ci/mcp-server), version `0.148.v6b_c057f27738` or later, installed on one or more controllers.

[](#_download_the_cloudbees_ci_mcp_router_image)Download the CloudBees CI MCP Router image
------------------------------------------------------------------------------------------

To use the CloudBees CI MCP Router, you must have the container image available locally for Docker or in your Kubernetes cluster. Choose one of the following methods depending on your deployment environment:

* [Download for Docker](#download-docker)

* [Download for Kubernetes](#download-k8s)

### [](#download-docker)Download for Docker

For local Docker use, manually download the CloudBees CI MCP Router image from [Docker Hub](https://hub.docker.com/r/cloudbees/ci-mcp-router):

    docker pull cloudbees/ci-mcp-router:<my-tag>(1)

**1**

Replace `<my-tag>` with the specific version or digest you intend to use.

### [](#download-k8s)Download for Kubernetes

For Kubernetes deployments, the image is pulled automatically by the cluster when a pod is created. To verify the image before use (recommended for production or regulated environments), pre-pull it to a node or private registry and verify as described below.

[](#verify-docker-image-signature)Verify the Docker image signature
-------------------------------------------------------------------

The CloudBees CI MCP Router Docker images are signed so you can verify their origin and authenticity. This helps protect against "man-in-the-middle" attacks and other forms of image tampering.

After the image is present locally (either pulled manually or by Kubernetes), verify its signature to ensure authenticity and integrity.

To verify the CloudBees CI MCP Router Docker images:

1. Download the [Cosign verification tool](https://github.com/sigstore/cosign#installation). Cosign is part of Sigstore, a suite of projects designed to simplify software signing.

2. Run one of the following commands to verify the authenticity of a specific CloudBees CI MCP Router Docker image.

    * Verify by digest:

            cosign verify --key https://cdn.cloudbees.com/keyring/cloudbees.pub cloudbees/ci-mcp-router@sha256:<my-digest>(1)

        **1**

        Replace `<my-digest>` with the specific SHA-256 digest of the image you want to verify, such as `abc123def456…`.

    * Verify by tag:

            cosign verify --key https://cdn.cloudbees.com/keyring/cloudbees.pub cloudbees/ci-mcp-router:<my-tag>(1)

        **1**

        Replace `<my-tag>` with the specific tag of the image you want to verify, such as `latest` or a version number, such as `1.2.3`.

    Cosign returns a message indicating whether the images are authentic. An exit code of `0` indicates that the images are authentic. If the images are not validated as authentic, contact [CloudBees Support](https://support.cloudbees.com).

[](#deploy-mcp-router)Deploy the CloudBees CI MCP Router
--------------------------------------------------------

To deploy the CloudBees CI MCP Router, choose one of the following methods based on your environment:

* [Deploy with Docker](#deploy-docker)

* [Deploy in Kubernetes](#deploy-k8s)

OpenID Connect (OIDC) configurations

If you use API token authentication and your operations center is configured to use OIDC, ensure the **Allow access using a Jenkins API token without an OIDC Session?** option is selected in the operations center. This allows API tokens to work without requiring a browser session.

If this option is not selected, you must first sign in to the operations center via a browser before deploying the CloudBees CI MCP Router, so your credentials are recognized as valid. If your browser session expires, sign in to the operations center again to refresh your session.

Before using this configuration, review and understand the security implications for your environment. If you have any questions or concerns, contact [CloudBees Support](https://support.cloudbees.com).

### [](#deploy-docker)Deploy with Docker

After verifying the image, you can run the CloudBees CI MCP Router locally using Docker:

    docker run -p 9000:9000 \
      -e OC_URL=<my-oc-url> \(1)
      -e MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL=<my-ttl> \(2)
      -e MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE=<my-mode> \(3)
      cloudbees/ci-mcp-router:<my-tag>(4)

**1**

Replace `<my-oc-url>` with the URL for your operations center.

**2**

Optional. Controls how long the CloudBees CI MCP Router caches the list of controllers from the operations center (default: `1H`). Decrease to detect newly provisioned controllers or controllers waking from hibernation faster; increase to reduce operations center load. Use suffixes `H` (hours), `M` (minutes), or `S` (seconds); for example, `1S` effectively disables caching.

**3**

Optional. Controls how access tokens are scoped when the router calls controllers (default: `FLEET`). `FLEET` generates one token covering all controllers (one authorization server round-trip); `PER_TARGET` generates one token per controller (one round-trip per controller). Use `PER_TARGET` when controllers are operated by different teams, to limit the scope of access if a controller is compromised.

**4**

Replace `<my-tag>` with the specific tag or digest you have already verified. The internal port used by the CloudBees CI MCP Router inside the container may vary depending on the image version or configuration. When exposing it externally, you can map any available host or cluster port to the internal port used by the router. Clients must connect to the mapped external port (for example, `http://localhost:9000/mcp`).

### [](#deploy-k8s)Deploy in Kubernetes

After verifying the image, you can reference it in your Kubernetes manifests as shown below.

The following excerpt shows only the relevant section of the deployment manifest.

    containers:
      - name: <my-app>(1)
        image: cloudbees/ci-mcp-router:my-tag(2)
        ports:
          - containerPort: 9000(3)
        env:
          - name: JAVA_TOOL_OPTIONS
            value: "-Doc.url=<my-oc-url>"(4)
          - name: MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL
            value: "<my-ttl>"(5)
          - name: MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE
            value: "<my-mode>"(6)

**1**

Replace `<my-app>` with the name of your container.

**2**

Replace `<my-tag>` with the specific tag or digest you have already verified (for example, `1.2.3` or `@sha256:abc123…​`). For security and reproducibility, do not use `latest`.

**3**

The internal port used by the CloudBees CI MCP Router inside the container may vary depending on the image version or configuration. When exposing it externally, you can map any available host or cluster port to the internal port used by the router. Clients must connect to the mapped external port (for example, `http://localhost:9000/mcp`).

**4**

Replace `<my-oc-url>` with the URL for your operations center.

**5**

Optional. Controls how long the CloudBees CI MCP Router caches the list of controllers from the operations center (default: `1H`). Decrease to detect newly provisioned controllers or controllers waking from hibernation faster; increase to reduce operations center load. Use suffixes `H` (hours), `M` (minutes), or `S` (seconds); for example, `1S` effectively disables caching.

**6**

Optional. Controls how access tokens are scoped when the router calls controllers (default: `FLEET`). `FLEET` generates one token covering all controllers (one authorization server round-trip); `PER_TARGET` generates one token per controller (one round-trip per controller). Use `PER_TARGET` when controllers are operated by different teams, to limit the scope of access if a controller is compromised.

In `FLEET` mode (the default), a compromised controller holds a token that is accepted by every other controller. When controllers are operated by different teams, set `MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE=PER_TARGET` to scope each token to a single controller.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/rate-limiting -->

# Enable rate limiting for the CloudBees CI MCP Router

Enable rate limiting for the CloudBees CI MCP Router
====================================================

The CloudBees CI MCP Router can cap how quickly a single caller reaches its `/mcp` endpoint, so that one misconfigured client or a runaway agent loop cannot flood the CloudBees CI MCP Router and overwhelm the controllers behind it. Rate limiting is disabled by default. Enable it when you are ready to protect a shared or public deployment.

[](#rate-limiting)How rate limiting works
-----------------------------------------

Rate limiting gives each caller its own allowance of requests over a rolling window of time. Each request consumes one unit of the allowance, which refills steadily as the window progresses. If you know the pattern, this is a per-identity token bucket.

While a caller stays within its allowance, its requests pass straight through without being rate limited. Once the allowance runs out, further requests receive an `HTTP 429 Too Many Requests` response with a `Retry-After` header that tells the client how long to wait before trying again.

The check runs at the very front of the `/mcp` endpoint, before any message is parsed, so it applies to the whole MCP conversation, including `initialize`, `tools/list`, and `tools/call`.

The CloudBees CI MCP Router identifies each caller in one of two ways:

* Authenticated callers are keyed by a hash of their `Authorization` header, so the raw credential is never stored, and each token or user gets its own allowance.

* Callers with no `Authorization` header are keyed by their client IP address, so one anonymous flood cannot lock everyone else out.

[](#enable-rate-limiting)Enable rate limiting
---------------------------------------------

To turn on rate limiting, set `MCP_RATE_LIMIT_ENABLED` to `true` on the CloudBees CI MCP Router when you [deploy it](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router). The remaining variables are optional; they refine the limit and take the defaults shown below.

If you deploy the CloudBees CI MCP Router with the `cloudbees-core` Helm chart, set these variables using [`McpRouter.extraEnv`](/docs/cloudbees-ci/latest/mcp-router/oauth#helm-values-product) instead.

Before you enable it, watch normal traffic for a while and pick a ceiling that leaves legitimate agents comfortable headroom. A good starting point is roughly twice your observed peak, which stops abuse without throttling healthy clients.

[](#rate-limiting-env-vars)Rate limiting environment variables
--------------------------------------------------------------

Environment variable

Possible values

Description

`MCP_RATE_LIMIT_ENABLED`

`true` or `false`  
(default: `false`)

The master switch. Set it to `true` to enforce rate limiting.

`MCP_RATE_LIMIT_PERMITS`

A positive whole number  
(default: `120`)

The maximum number of requests each caller can make within one window.

`MCP_RATE_LIMIT_WINDOW`

A number with the suffix `H` (hours), `M` (minutes), or `S` (seconds), such as `1M` or `30S`  
(default: `1M`)

The window over which each caller’s allowance refills.

`MCP_RATE_LIMIT_MAX_BUCKETS`

A positive whole number  
(default: `100000`)

The maximum number of distinct callers tracked at once. When this limit is reached, the limiter evicts the least recently seen caller, which caps how much memory it can use.

`MCP_RATE_LIMIT_TRUST_FORWARDED_FOR`

`true` or `false`  
(default: `false`)

Whether to trust the `X-Forwarded-For` header when keying anonymous callers by IP address. Leave it disabled unless a trusted proxy sets the header. For more information, refer to [Security considerations](#security-considerations).

With the defaults, each caller is allowed 120 requests per minute.

[](#security-considerations)Security considerations
---------------------------------------------------

Rate limiting is a protective control, so keep the following in mind when you configure it.

Enable `MCP_RATE_LIMIT_TRUST_FORWARDED_FOR` only when a trusted ingress or load balancer sets the `X-Forwarded-For` header. Clients can forge that header, so if the CloudBees CI MCP Router is directly reachable, a caller could dodge the limit by sending a different value on every request. When the setting is disabled (the default), anonymous callers are keyed by the IP address of their direct connection instead.

Rate limiting protects availability, not access. It limits how often a caller can reach the CloudBees CI MCP Router, but it does not authenticate or authorize anyone, so keep [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth) or another authentication method in place as well.

Authenticated callers are keyed by a hash of their `Authorization` header, so raw tokens and passwords are never stored. `MCP_RATE_LIMIT_MAX_BUCKETS` also caps how many callers are tracked at once and evicts the least recently seen when the cap is reached, so a flood of ever-changing identities cannot grow the limiter’s memory without bound.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/authenticate -->

# Configure authentication

Configure authentication
========================

The CloudBees CI MCP Router supports two ways to authenticate to CloudBees CI: OAuth and API token. OAuth is recommended because each request carries the identity of the user or tool that made it. The CloudBees CI MCP Router stores only short-lived tokens scoped to the controllers it needs to access, rather than relying on a single shared token.

Choose the method that fits your environment:

* [Enable OAuth authentication for the CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/oauth) (recommended)

* [Authenticate with an API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication)

    Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/oauth -->

# Enable OAuth authentication for the CloudBees CI MCP Router

Enable OAuth authentication for the CloudBees CI MCP Router
===========================================================

OAuth is the recommended way for the CloudBees CI MCP Router to authenticate to CloudBees CI. Rather than relying on one shared token, each request carries the identity of the person or tool that made it, and the CloudBees CI MCP Router holds only short-lived tokens scoped to the controllers it needs to reach. OAuth uses the following components:

* An MCP client (such as Claude Code or GitHub Copilot) signs in once and sends an OAuth token to the CloudBees CI MCP Router.

* The CloudBees CI MCP Router exchanges that token for a short-lived token scoped to the controller it needs to reach, then forwards the request.

* The controller validates the token and runs the request as the signed-in user.

Review the [Prerequisites](#prerequisites) and [Pre-seeded OAuth clients](#pre-seeded-oauth-clients), and then choose one of the following methods to enable OAuth:

* [Enable OAuth with Helm](#enable-helm)

* [Manually configure OAuth](#configure-manually)

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have the following:

* The [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource), installed on the operations center and on every controller that should accept OAuth, and each instance restarted after installation.

    If your controllers are connected to the operations center, you do not need to configure each controller manually. When a controller connects to the operations center, it is automatically configured with the authorization server to trust.

* The [CloudBees OAuth Authorization Server plugin](/plugins/ci/cloudbees-oauth-server), installed on the operations center and the instance restarted after installation.

* The CloudBees CI MCP Router [installed](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router) and running.

[](#pre-seeded-oauth-clients)Pre-seeded OAuth clients
-----------------------------------------------------

The authorization server ships with two pre-seeded OAuth clients, so no client registration is required to connect an MCP agent:

* `cloudbees-mcp-router`: A confidential client, using the token-exchange grant, that the CloudBees CI MCP Router uses to exchange a user token for a controller-scoped token.

* `ci-mcp-client`: A public client, using [Proof Key for Code Exchange (PKCE)](https://oauth.net/2/pkce/), that MCP agents such as Claude Code use to sign in. Select it with the `--client-id ci-mcp-client` flag when you connect an agent.

Because these two clients are pre-seeded, an MCP agent using `ci-mcp-client` connects without needing to register first. On first use, you are asked to approve the client’s access, unless an administrator has enabled **Auto-approve seeded clients** on the authorization server.

Dynamic client registration (DCR) is disabled by default. Requests to the `/oauth-server/register` endpoint return a `403` error unless you re-enable DCR in the **CloudBees OAuth Authorization Server** configuration, or by setting `dcrEnabled: true` in CasC.

Re-enable it only for environments that need self-service registration, such as test clusters or the MCP Inspector. Any client you create manually still prompts for consent on first use.

[](#enable-helm)Enable OAuth with Helm
--------------------------------------

If you already deploy CloudBees CI with the `cloudbees-core` Helm chart, you can deploy the CloudBees CI MCP Router and enable OAuth together by adding the following values.

Before proceeding, ensure you have the following:

* CloudBees CI version 2.541.2.35785 or later.

* The [MCP Server plugin](/plugins/ci/mcp-server), version `0.148.v6b_c057f27738` or later, installed on one or more controllers.

The following steps cover the settings sufficient for most deployments. For additional tuning options, refer to [(Optional) Tune the Helm configuration](#helm-values).

1. Add the following to your Helm values:

        OperationsCenter:
          OAuthServer:
            Enabled: true(1)
        McpRouter:
          enabled: true(2)
          upstreamMode: AUTO(3)

    **1**

    Turns on the authorization server and its discovery endpoints.

    **2**

    Deploys the CloudBees CI MCP Router as part of the chart. Omit if you already [manually deployed the CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

    **3**

    `AUTO` accepts both OAuth bearer tokens and existing `Authorization` headers (such as Basic or API token), which is the recommended choice when you migrate to OAuth. Update to `OAUTH_ONLY` after every controller has the [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) installed and configured.

2. Apply the values:

        helm upgrade cloudbees-core cloudbees/cloudbees-core --reset-then-reuse-values \
          --set OperationsCenter.OAuthServer.Enabled=true \
          --set McpRouter.enabled=true(1)

    **1**

    Omit if you already [manually deployed the CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

    The chart automatically:

    * Configures the authorization server with the addresses allowed to receive tokens (the CloudBees CI MCP Router and the controllers).

    * Configures the operations center and controllers with the authorization server to trust.

    * Exposes the OAuth discovery endpoints so that MCP clients can locate them.

    * Runs the CloudBees CI MCP Router under a dedicated Kubernetes service account and grants it a projected token (audience `cjoc`) that the authorization server validates to authenticate token-exchange requests; no shared secret is required.

### [](#helm-values)(Optional) Tune the Helm configuration

The values described in [Enable OAuth with Helm](#enable-helm) are sufficient for most deployments. The following values let you tune the authorization server and the CloudBees CI MCP Router when the defaults do not suit your environment.

Tune authorization server values

Value

Description

`OperationsCenter.OAuthServer.Enabled`

Renders the OAuth discovery endpoints and configuration that seeds the [CloudBees OAuth Authorization Server plugin](/plugins/ci/cloudbees-oauth-server) and [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) on every operations center start. Grants the CloudBees CI MCP Router a projected service account token to authenticate to the authorization server. Set to `true` when the [CloudBees OAuth Authorization Server plugin](/plugins/ci/cloudbees-oauth-server) is installed on the operations center.  
Default: `false`

`OperationsCenter.OAuthServer.RouterAudience`

Public address of the CloudBees CI MCP Router that the authorization server expects in the `aud` claim of exchanged tokens. Ignored when `McpRouter.enabled` is `true`, because the chart then derives the audience from the cluster URL. Set it only for a CloudBees CI MCP Router that runs outside the cluster.  
Default: `http://localhost:9000`

Tune CloudBees CI MCP Router deployment values

Value

Description

`McpRouter.enabled`

The chart renders a Deployment, Service, and Ingress wired to the operations center. Set to `true` to deploy the CloudBees CI MCP Router as part of the chart.  
Default: `false`

`McpRouter.upstreamMode`

Authentication mode forwarded to controllers.  
Default: `AUTO`

* `AUTO`: Exchanges a validated OAuth bearer token for a controller-scoped token, and forwards any other `Authorization` header (such as Basic or API token) verbatim.

* `OAUTH_ONLY`: Requires an OAuth bearer token and rejects any other request.

Use `AUTO` while migrating, then switch to `OAUTH_ONLY` once every controller has the [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) installed and configured. `OAUTH_ONLY` requires `OperationsCenter.OAuthServer.Enabled` to be `true`.

`McpRouter.privateKeyJwt.enabled`  
`McpRouter.privateKeyJwt.keySecretName`  
`McpRouter.privateKeyJwt.keySecretKey`

By default, the CloudBees CI MCP Router authenticates to the authorization server with its projected service account token. To use an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `private_key_jwt` assertion instead, set these values:

* `enabled`: Controls the `private_key_jwt` mode for the token exchange between the CloudBees CI MCP Router and the operations center.

  * `NEVER` (default): Uses the projected service account token.

  * `ALWAYS`: Signs with the shared key. The chart mounts `keySecretName` if set. Otherwise, it generates a key and keeps it.

  * `AUTO`: Signs only when `keySecretName` is set. Otherwise, it falls back to the projected service account token.

* `keySecretName`: The name of a Kubernetes Secret holding the RSA signing key in PEM format. The key is shared by every CloudBees CI MCP Router replica, so all pods publish one `kid` at `/jwks`.

* `keySecretKey`: The entry (file name) of the PEM within that Secret. Default: `signing-key.pem`.

When `enabled` is `ALWAYS` and no `keySecretName` is set, the chart generates a signing key and stores it in a Secret named `mcp-router-signing-key`. This works for plain Helm, but under GitOps or `--dry-run`, the chart cannot look up the existing Secret and might regenerate the key. In those environments, create and name your own Secret:

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out signing-key.pem
    kubectl create secret generic mcp-router-signing-key --from-file=signing-key.pem

Default: `enabled: NEVER`

`McpRouter.replicas`

Number of CloudBees CI MCP Router replicas. The CloudBees CI MCP Router keeps only in-memory caches, so one replica is enough for most fleets.  
Default: `1`

`McpRouter.image.registry`  
`McpRouter.image.repository`  
`McpRouter.image.tag`

CloudBees CI MCP Router image coordinates. Override any of these to pull from a private registry or to pin a specific version. Set `McpRouter.image.dockerImage` to a full image path to override all image coordinates at once.  
Default: Chart default values.

`McpRouter.image.pullPolicy`

Image pull policy for the CloudBees CI MCP Router container.  
Default: `IfNotPresent`

`McpRouter.resources`

CPU, memory requests, and limits for the CloudBees CI MCP Router container. Requests and limits are set to the same value so the pod runs in the Kubernetes Guaranteed QoS class.  
Default: `1` CPU / `2Gi` for both requests and limits

`McpRouter.extraEnv`

Extra environment variables for the CloudBees CI MCP Router container, for example to set `mcp.router.*` properties, such as the controller cache TTL.  
Default: `[]`

For example, to set the controller cache TTL:

    McpRouter:
      extraEnv:
        - name: MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL
          value: "10M"

`McpRouter.ocInternalUrl`

Direct operations center service URL for calls from the CloudBees CI MCP Router to the operations center, bypassing the ingress. Use it to prevent hairpin NAT issues on GKE or EKS. Leave empty to compute it automatically from `OperationsCenter.Name` and `OperationsCenter.ContextPath` (for example, `http://cjoc/cjoc` for a standard installation). The operations center URL (`OC_URL`) remains the OAuth audience regardless of this setting.  
Default: `""`

`McpRouter.javaOpts`

Additional Java options for the CloudBees CI MCP Router JVM. They are appended to the image's built-in `JAVA_OPTS_APPEND` flags, so the computed memory and garbage collection defaults and the image's Quarkus flags are preserved.  
Default: not set

`McpRouter.imagePullSecrets`

Image pull secrets for a private registry.

`McpRouter.nodeSelector`  
`McpRouter.tolerations`  
`McpRouter.annotations`  
`McpRouter.podSecurityContext`  
`McpRouter.containerSecurityContext`

Standard Kubernetes scheduling, annotation, and security context settings for the CloudBees CI MCP Router pod and container.

[](#configure-manually)Manually configure OAuth
-----------------------------------------------

If you do not use the Helm chart, you must configure the OAuth components manually. Configure the authorization server and resource server in CloudBees CI, and then start the CloudBees CI MCP Router with the corresponding environment variables.

To manually configure OAuth:

1. Configure the authorization server and resource server using one of the following methods:

    * [Configure using the UI](#configure-with-ui).

    * [Configure using Configuration as Code](#configure-with-casc).

2. [Configure the CloudBees CI MCP Router](#configure-product).

### [](#configure-with-ui)Configure the authorization server and resource server using the UI

To configure the authorization server and resource server in the CloudBees CI UI:

The following steps cover the settings sufficient for most deployments. For additional tuning options, refer to [(Optional) Tune the manual configuration](#tune-manual-config).

1. [Configure the resource server (operations center and controllers)](#configure-resource-server-ui).

2. [Configure the authorization server (operations center only)](#configure-auth-server-ui).

#### [](#configure-resource-server-ui)Configure the resource server (operations center and controllers)

To configure the resource server on the operations center and on every controller that should accept OAuth:

1. In the operations center and on each controller, navigate to **Manage Jenkins**  **Security** and scroll down to **CloudBees OAuth Resource Server**.

2. Set **Trusted issuer** to the issuer URL of the authorization server.

    This value must match the **Issuer URL** of the authorization server exactly. If you use the default authorization server URL, enter `<your-oc-url>/oauth-server`. If left blank, OAuth enforcement is disabled and all requests pass through to Jenkins.

3. If the canonical address of this instance differs from its root URL, set **Accepted audience** to the canonical address. Otherwise, leave it blank to use the root URL.

4. Set **Filter mode** to one of the following:

    * **AUTO** (recommended): Accepts both OAuth bearer tokens and existing sign-ins; non-Bearer requests are handled by Jenkins directly.

    * **OAUTH\_ONLY**: Accepts the same bearer tokens as **AUTO**, but challenges non-Bearer requests to protected paths with `401 + PRM`.

    * **ROUTER\_ONLY**: Accepts only tokens issued through the CloudBees CI MCP Router and rejects all other requests to protected paths.

5. Select **Save** to apply the changes.

#### [](#configure-auth-server-ui)Configure the authorization server (operations center only)

To configure the authorization server on the operations center:

1. In the operations center, navigate to **Manage Jenkins**  **Security** and scroll down to **CloudBees OAuth Authorization Server**.

2. Leave **Issuer URL** blank to use the default, `<your-oc-url>/oauth-server`, which matches the **Trusted issuer** value set on the resource server. If the authorization server is reachable at a different public address than the operations center, set **Issuer URL** to that address instead.

3. Leave **Internal JWKS URL** blank in most cases; controllers fetch the signing keys from the issuer’s public `/jwks` endpoint. Set it only if a controller cannot reach that public address, for example an internal address reachable only over HTTP. For more information, refer to [Resolve OAuth configuration issues](/docs/cloudbees-ci/latest/mcp-router/troubleshooting#oauth-config-issues).

4. For **Allowed audiences**, add the addresses of the controllers and the CloudBees CI MCP Router that are allowed to receive exchanged tokens, one per line.

5. Set **Router client secret** to a strong random secret. Record it, as you will need it when you [configure the CloudBees CI MCP Router](#configure-product), where it is set as `ROUTER_CLIENT_SECRET`.

6. Select **Save** to apply the changes.

### [](#tune-manual-config)(Optional) Tune the manual configuration

The settings above are sufficient for most deployments. The following settings let you tune the resource server and authorization server when the defaults do not fit your environment.

Tune resource server settings (operations center and controllers)

1. In the operations center and on each controller, navigate to **Manage Jenkins**  **Security** and scroll down to **CloudBees OAuth Resource Server**.

2. Leave **JWKS URL override** blank in most cases; by default the JWKS is fetched from `{trustedIssuer}/jwks` over HTTPS. Set it only if this instance’s public hostname is unreachable from inside the cluster (hairpin NAT), to an internal address such as `http://cjoc/cjoc/oauth-server/jwks`.

3. If you selected **ROUTER\_ONLY** for **Filter mode**, set **PRM resource URI** to the CloudBees CI MCP Router URL, so MCP clients discover CloudBees CI MCP Router instead of connecting to Jenkins directly.

4. If MCP endpoints on this instance are served from a path other than `/mcp-server/*`, add those paths to **Protected paths**, one per line or comma-separated.

5. If you need to tune how long JWKS keys are cached, adjust **JWKS cache TTL** (default: 300 seconds).

6. If you need to adjust the leeway for token expiry validation, adjust **Clock skew** (default: 60 seconds).

Tune authorization server settings (operations center only)

1. In the operations center, navigate to **Manage Jenkins**  **Security** and scroll down to **CloudBees OAuth Authorization Server**.

2. If you want the operations center to overwrite any locally set trusted issuer on connected controllers, select **Enforce trusted issuer on controllers**. Otherwise, the operations center seeds its issuer only on controllers that have none, leaving deliberate local values alone.

3. If your security policy requires shorter token lifetimes than the defaults, adjust **Access token TTL** (default: 600 seconds) and **Exchanged token TTL** (default: 300 seconds). Exchanged tokens should be shorter than access tokens, because they can always be re-exchanged.

4. To let untrusted clients self-register (for example, MCP Inspector or similar tooling that automatically registers), select **Enable Dynamic Client Registration**. For more information, refer to [Pre-seeded OAuth clients](#pre-seeded-oauth-clients).

    Leave this disabled on a publicly reachable authorization server to prevent unbounded client creation.

5. If you selected **Enable Dynamic Client Registration** and an MCP client fails to register because it looks for `/register` at the Jenkins root instead of at `/oauth-server/register`, enable **Also serve /register at Jenkins root**.

6. If you selected **Enable Dynamic Client Registration** and your security policy requires different DCR client lifetimes than the defaults, adjust **DCR client secret TTL** (default: 180 days), **DCR refresh-token TTL** (default: 30 days), and **Idle DCR client TTL** (default: 90 days).

    These lifetimes are entered in seconds in the UI.

7. If you selected **Enable Dynamic Client Registration** and want to manage clients manually through the UI, disable **Evict idle DCR clients**. Otherwise, leave it enabled so the daily sweep evicts idle DCR clients.

8. To bypass the consent prompt on first use for the pre-seeded `cloudbees-mcp-router` and `ci-mcp-client` clients, enable **Auto-approve seeded clients**.

    Enable this only if you accept that these platform clients act on a user’s identity without explicit approval.

9. If clients authenticate with `private_key_jwt` and your security policy requires different client assertion or JWKS lifetimes than the defaults, adjust **Client assertion max lifetime** (default: 300 seconds), **Client assertion clock skew** (default: 30 seconds), and **JWKS cache TTL** (default: 300 seconds).

    This **JWKS cache TTL** is separate from the resource server setting of the same name. Here it controls how long the authorization server caches the public keys it fetches to verify client assertions.

10. If you use the RFC 7523 jwt-bearer grant to trade external JWTs (such as Kubernetes service account tokens or GitHub Actions OIDC tokens) for CloudBees CI MCP Router tokens, under **Trusted assertion issuers**, select **\+ Add trusted issuer**, and then configure the following for each external issuer:

     * Set **Issuer (iss)** to the exact value of the assertion’s `iss` claim, for example, `https://token.actions.githubusercontent.com` or the Kubernetes API server issuer.

     * Set **Expected audience (aud)** to a value unique to this authorization server, so a token minted for another service cannot be replayed at this endpoint.

     * Set **Bound Jenkins user id** to the Jenkins user that every assertion from this issuer maps to. The external token never chooses its own identity; you pin it here.

     * Provide the issuer’s public keys as either **Inline JWKS** or a **JWKS URL**. Prefer **JWKS URL** when the issuer rotates keys.

     * Optionally, in **Allowed audiences**, add the audiences this issuer’s tokens may target, one per line. Leave blank to inherit the global **Allowed audiences** list.

     * Optionally, in **Allowed subjects**, add the external `sub` values to accept from this issuer, one per line. Leave blank to accept any subject the issuer vouches for.

         For a shared issuer such as GitHub Actions, set **Allowed subjects** so that only specific external identities can become the bound user, rather than anyone who can mint a token for the expected audience.

### [](#configure-with-casc)Configure the authorization server and resource server using Configuration as Code

To configure using Configuration as Code (CasC):

1. In the operations center CasC bundle, add the following to your `jenkins.yaml` file:

        security:
          oauthAuthorizationServer:
            issuer: "https://oc.example.com/oauth-server"(1)
            routerClientSecret: "<your-shared-secret>"(2)
            allowedAudiences: |(3)
              https://controller-a.example.com
              https://mcp-router.example.com
            internalJwksUrl: "<internal-address>"(4)

    **1**

    Public address of the authorization server.

    **2**

    Shared secret the CloudBees CI MCP Router uses to authenticate to the authorization server. Use the same value as `ROUTER_CLIENT_SECRET` (refer to [Configure the CloudBees CI MCP Router](#configure-product)).

    **3**

    Addresses of the controllers and the CloudBees CI MCP Router that are allowed to receive exchanged tokens, with one address per line.

    **4**

    Optional; usually leave it unset so controllers derive the issuer’s public HTTPS `/jwks` endpoint. Set it only if a controller cannot reach that public address, for example an internal address reachable only over HTTP. For more information, refer to [Resolve OAuth configuration issues](/docs/cloudbees-ci/latest/mcp-router/troubleshooting#oauth-config-issues).

2. In the CasC bundle for the operations center and each controller, add the following to your `jenkins.yaml` file:

        security:
          oauthResourceServer:
            trustedIssuer: "https://oc.example.com/oauth-server"(1)
            acceptedAudience: "https://controller-a.example.com"(2)
            filterMode: "AUTO"(3)

    **1**

    Trusted issuer URL of the authorization server. It must match `issuer` exactly. OAuth remains disabled until this is set.

    **2**

    Canonical address of this instance. Defaults to the instance root URL.

    **3**

    `AUTO` accepts both OAuth and existing sign-ins. `OAUTH_ONLY` accepts the same bearer tokens as `AUTO`, but challenges non-Bearer requests to protected paths with `401 + PRM`. `ROUTER_ONLY` accepts only tokens issued through the CloudBees CI MCP Router.

3. Apply the bundle to your operations center and controllers. For more information, refer to [Update a CasC bundle](/docs/cloudbees-ci/latest/casc-update-bundle/update-bundle).

### [](#configure-product)Configure the CloudBees CI MCP Router

Start the CloudBees CI MCP Router with the following environment variables:

    docker run -p 9000:9000 \
      -e OC_URL=https://oc.example.com \
      -e OAUTH_ENABLED=true \
      -e OAUTH_ISSUER=https://oc.example.com/oauth-server \
      -e OAUTH_ROUTER_AUDIENCE=https://mcp-router.example.com \
      -e ROUTER_CLIENT_ID=cloudbees-mcp-router \
      -e ROUTER_CLIENT_SECRET=<your-shared-secret> \
      -e MCP_AUTH_UPSTREAM_MODE=AUTO \
      cloudbees/ci-mcp-router:<my-tag>

The following values must match the authorization server configuration:

* `OAUTH_ISSUER` must match the **Issuer URL**.

* `ROUTER_CLIENT_SECRET` must match the **Router client secret**.

* `OAUTH_ROUTER_AUDIENCE` is the public address of the CloudBees CI MCP Router, and must appear in the **Allowed audiences** list of the authorization server.

The router client secret allows the CloudBees CI MCP Router to obtain tokens, so protect it as you would a password. Use a Kubernetes Secret or a secret store rather than passing it on the command line, where it can be exposed in shell history or process listings.

[](#verify-oauth)Verify OAuth is working
----------------------------------------

1. Verify that the authorization server is published. The following command returns a JSON document that describes the available endpoints:

        curl https://oc.example.com/oauth-server/oauth-authorization-server

2. Verify that the signing keys are available:

        curl https://oc.example.com/oauth-server/jwks

3. Verify that a controller advertises OAuth:

        curl https://controller-a.example.com/.well-known/oauth-protected-resource

4. After connecting an MCP agent as described in [Connect the MCP agent](/docs/cloudbees-ci/latest/mcp-router/mcp-agent), verify that you are prompted to sign in through OAuth instead of entering an API token.

    If verification fails, refer to [Resolve OAuth configuration issues](/docs/cloudbees-ci/latest/mcp-router/troubleshooting#oauth-config-issues).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/token-authentication -->

# Authenticate with an API token

Authenticate with an API token
==============================

The CloudBees CI MCP Router can authenticate to CloudBees CI with an API token generated from the operations center and encoded for HTTP basic authentication.

Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

[](#_prerequisites)Prerequisites
--------------------------------

Before you begin, ensure that you have [installed the CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router) and have an account with sufficient permissions to generate an API token in the operations center.

[](#generate-api-token)Generate an API token
--------------------------------------------

You must generate an API token from the operations center.

If you generate an API token from a controller instead of the operations center, the token is not valid for use with the CloudBees CI MCP Router and a connection cannot be established.

To generate an API token:

1. Sign in to the operations center.

2. Select in the upper-right corner, and then select **Security**.

3. Select **Add new token**.

4. Enter a name to distinguish the token, and then select **Generate**.

5. Copy the token and store it in a secure location for later use.

    Once you leave the page, you cannot view or copy the token again.

6. Select **Done** to add the token.

7. Select **Save** to save your changes.

[](#encode-token)Encode credentials for HTTP basic authentication
-----------------------------------------------------------------

Authenticate with the CloudBees CI MCP Router using HTTP basic authentication by encoding your username and API token together.

To encode credentials on Linux, macOS, or Windows:

Open a terminal and run the following command, replacing `<username>` and `<token>` with your actual username and the API token you generated in the operations center:

Linux or macOS

Windows (PowerShell)

    echo -n "<username>:<token>" | base64

    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("<username>:<token>"))

If successful, the Base64-encoded credential is output, similar to the following:

    dXNlcm5hbWU6dG9rZW4=

Store the encoded credential in a secure location for later use.

Base64 encoding is not encryption. Anyone with access to the encoded string can decode it and obtain your credentials. Always protect the encoded credentials as if they are the original username and token.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/mcp-agent -->

# Connect the MCP agent

Connect the MCP agent
=====================

MCP agents empower your team to automate and streamline CI workflows by connecting MCP-compatible tools to CloudBees CI. With support for multiple controllers, you can securely access and manage jobs, builds, and resources across your entire environment. The CloudBees CI MCP Router extends Jenkins capabilities, so you can programmatically interact with Jenkins, automate routine tasks, and enhance your development process using real-time data.

* [Connect Claude Code](/docs/cloudbees-ci/latest/mcp-router/claude-code)

* [Connect GitHub Copilot](/docs/cloudbees-ci/latest/mcp-router/github-copilot)

* [Connect Goose](/docs/cloudbees-ci/latest/mcp-router/goose)

* [Connect Kiro](/docs/cloudbees-ci/latest/mcp-router/kiro)

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/claude-code -->

# Connect Claude Code to the CloudBees CI MCP Router

Connect Claude Code to the CloudBees CI MCP Router
==================================================

Claude Code is an AI-powered command-line interface (CLI) tool that integrates with the CloudBees CI MCP Router through the [MCP Server plugin](/plugins/ci/mcp-server), connecting your development environment to CloudBees CI. This enables context-aware code suggestions and automation using real CloudBees CI data, so you can interact with Jenkins resources directly from your development environment.

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have:

* The [CloudBees CI MCP Router installed](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

* Configured authentication using [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth) or an [API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication).

* Claude Code installed.

[](#connect-agent)Connect Claude Code
-------------------------------------

After completing the prerequisites, connect Claude Code to the CloudBees CI MCP Router using the authentication method you configured.

* [Connect with OAuth](#connect-oauth) (recommended)

* [Connect with an API token](#connect-token)

### [](#connect-oauth)Connect with OAuth

With [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), you do not need to pass credentials to the command line. You sign in once, and the CloudBees CI MCP Router handles the rest.

To connect Claude Code to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Claude Code is installed.

2. Run the following command to add CloudBees CI MCP Router to Claude Code:

        claude mcp add ci-mcp-router <router-url> --transport http --client-id ci-mcp-client(1)

    **1**

    Replace `<router-url>` with the MCP endpoint of your CloudBees CI MCP Router: `http://localhost:9000/mcp` for a local Docker deployment, or `https://<cluster-domain>/mcp-router/mcp` for a Helm deployment.

    The `--client-id ci-mcp-client` flag selects the [pre-seeded public client](/docs/cloudbees-ci/latest/mcp-router/oauth#pre-seeded-oauth-clients). Without it, Claude Code attempts dynamic client registration, which is disabled by default and fails with a `403` error.

3. Start Claude Code:

        claude

4. Run the `/mcp` command:

        /mcp

5. Select the `ci-mcp-router` server. A browser launches with an approval prompt. After you approve, Claude Code reuses the session for later requests.

### [](#connect-token)Connect with an API token

Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

To connect Claude Code to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Claude Code is installed.

2. Run the following command to add CloudBees CI MCP Router to Claude Code, including the encoded HTTP basic authentication credentials you generated in [Authenticate with an API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication):

        claude mcp add ci-mcp-router http://localhost:9000/mcp --transport http --header "Authorization: Basic dXNlcm5hbWU6dG9rZW4="(1)

    **1**

    Replace `dXNlcm5hbWU6dG9rZW4=` with your actual encoded credentials.

    Passing the encoded credential directly in this command leaves it in your shell history, and storing it as plain text in your MCP configuration file leaves it exposed to any process that can read that file.

    Claude Code lets you reference an environment variable in the header value instead of the literal credential. For more information, refer to [Environment variable expansion in `.mcp.json`](https://code.claude.com/docs/en/mcp#environment-variable-expansion-in-mcp-json) for details.

    If properly configured, a confirmation message similar to the following is returned:

        The CloudBees CI MCP Router has been successfully added to your Claude Code configuration. It's now configured to connect to your local Jenkins instance at
          http://localhost:9000/mcp with the provided authorization header.

3. Start Claude Code:

        claude

    Claude Code connects using the credentials you provided.

[](#use-agent)Use Claude Code for development tasks
---------------------------------------------------

Now that Claude Code is connected to the CloudBees CI MCP Router, you can use the following tools and commands to accelerate your development workflow. For a list of supported tools, refer to [CloudBees CI MCP Router tool reference](/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/github-copilot -->

# Connect GitHub Copilot to the CloudBees CI MCP Router

Connect GitHub Copilot to the CloudBees CI MCP Router
=====================================================

GitHub Copilot is an AI-powered command-line interface (CLI) tool that integrates with the CloudBees CI MCP Router through the [MCP Server plugin](/plugins/ci/mcp-server), connecting your development environment to CloudBees CI. This enables context-aware code suggestions and automation using real CloudBees CI data, so you can interact with Jenkins resources directly from your development environment.

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have:

* The [CloudBees CI MCP Router installed](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

* Configured authentication using [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth) or an [API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication).

* GitHub Copilot installed.

[](#connect-agent)Connect GitHub Copilot
----------------------------------------

After completing the prerequisites, connect GitHub Copilot to the CloudBees CI MCP Router using the authentication method you configured.

* [Connect with OAuth](#connect-oauth) (recommended)

* [Connect with an API token](#connect-token)

### [](#connect-oauth)Connect with OAuth

With [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), you do not need to pass credentials to the command line. You sign in once, and the CloudBees CI MCP Router handles the rest.

To connect GitHub Copilot to the CloudBees CI MCP Router:

1. Open a terminal on the machine where GitHub Copilot is installed.

2. Run the following command to add CloudBees CI MCP Router to GitHub Copilot:

        copilot mcp add --transport http ci-mcp-router <router-url>(1)

    **1**

    Replace `<router-url>` with the MCP endpoint of your CloudBees CI MCP Router: `http://localhost:9000/mcp` for a local Docker deployment, or `https://<cluster-domain>/mcp-router/mcp` for a Helm deployment.

3. Start GitHub Copilot:

        copilot

    A browser launches with an approval prompt. After you approve, GitHub Copilot reuses the session for later requests.

### [](#connect-token)Connect with an API token

Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

To connect GitHub Copilot to the CloudBees CI MCP Router:

1. Open a terminal on the machine where GitHub Copilot is installed.

2. Run the following command to add CloudBees CI MCP Router to GitHub Copilot, including the encoded HTTP basic authentication credentials you generated in [Authenticate with an API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication):

        copilot mcp add ci-mcp-router --transport http http://localhost:9000/mcp --header "Authorization: Basic dXNlcm5hbWU6dG9rZW4="(1)

    **1**

    Replace `dXNlcm5hbWU6dG9rZW4=` with your actual encoded credentials.

    Passing the encoded credential directly in this command leaves it in your shell history, and storing it as plain text in your MCP configuration file leaves it exposed to any process that can read that file.

    GitHub Copilot has no confirmed way to reference an environment variable in this field. Treat this configuration file as sensitive, keep it out of version control, and rotate the credential if it’s ever exposed.

3. Start GitHub Copilot:

        copilot

    GitHub Copilot connects using the credentials you provided.

[](#use-agent)Use GitHub Copilot for development tasks
------------------------------------------------------

Now that GitHub Copilot is connected to the CloudBees CI MCP Router, you can use the following tools and commands to accelerate your development workflow. For a list of supported tools, refer to [CloudBees CI MCP Router tool reference](/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/goose -->

# Connect Goose to the CloudBees CI MCP Router

Connect Goose to the CloudBees CI MCP Router
============================================

Goose is an AI-powered command-line interface (CLI) tool that integrates with the CloudBees CI MCP Router through the [MCP Server plugin](/plugins/ci/mcp-server), connecting your development environment to CloudBees CI. This enables context-aware code suggestions and automation using real CloudBees CI data, so you can interact with Jenkins resources directly from your development environment.

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have:

* The [CloudBees CI MCP Router installed](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

* Configured authentication using [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth) or an [API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication).

* Goose installed.

[](#connect-agent)Connect Goose
-------------------------------

After completing the prerequisites, connect Goose to the CloudBees CI MCP Router using the authentication method you configured.

* [Connect with OAuth](#connect-oauth) (recommended)

* [Connect with an API token](#connect-token)

### [](#connect-oauth)Connect with OAuth

With [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), you do not need to pass credentials to the command line. You sign in once, and the CloudBees CI MCP Router handles the rest.

To connect Goose to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Goose is installed.

2. Run the `goose configure` command to start the interactive configuration process:

        ┌   goose-configure
        │
        ◇  What would you like to configure?
        │  Add Extension
        │
        ◇  What type of extension would you like to add?
        │  Remote Extension (Streamable HTTP)
        │
        ◇  What would you like to call this extension?
        │  CloudBees CI MCP Router(1)
        │
        ◇  What is the Streaming HTTP endpoint URI?
        │  <router-url>(2)
        │
        ◇  Please set the timeout for this tool (in secs):
        │  300(3)
        │
        ◇  Enter a description for this extension:
        │  CloudBees CI MCP Router for Jenkins
        │
        ◇  Would you like to add custom headers?
        │  No
        │
        └  Added CloudBees CI MCP Router extension

    **1**

    You can name the extension whatever you prefer.

    **2**

    Replace `<router-url>` with the MCP endpoint of your CloudBees CI MCP Router: `http://localhost:9000/mcp` for a local Docker deployment, or `https://<cluster-domain>/mcp-router/mcp` for a Helm deployment.

    **3**

    The default timeout is 300 seconds. You can adjust this value as needed.

3. Start Goose:

        goose session

    A browser launches with an approval prompt. After you approve, Goose reuses the session for later requests.

### [](#connect-token)Connect with an API token

Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

To connect Goose to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Goose is installed.

2. Run the `goose configure` command to start the interactive configuration process:

        ┌   goose-configure
        │
        ◇  What would you like to configure?
        │  Add Extension
        │
        ◇  What type of extension would you like to add?
        │  Remote Extension (Streamable HTTP)
        │
        ◇  What would you like to call this extension?
        │  CloudBees CI MCP Router(1)
        │
        ◇  What is the Streaming HTTP endpoint URI?
        │  http://localhost:9000/mcp
        │
        ◇  Please set the timeout for this tool (in secs):
        │  300(2)
        │
        ◇  Enter a description for this extension:
        │  CloudBees CI MCP Router for Jenkins
        │
        ◇  Would you like to add custom headers?
        │  Yes
        │
        ◇  Header name:
        │  Authorization
        │
        ◇  Header value:
        │  Basic dXNlcm5hbWU6dG9rZW4=(3)
        │
        ◇  Add another header?
        │  No
        │
        └  Added CloudBees CI MCP Router extension

    **1**

    You can name the extension whatever you prefer.

    **2**

    The default timeout is 300 seconds. You can adjust this value as needed.

    **3**

    Replace `dXNlcm5hbWU6dG9rZW4=` with your actual encoded credentials.

    Passing the encoded credential directly in this command leaves it in your shell history, and storing it as plain text in your MCP configuration file leaves it exposed to any process that can read that file.

    Goose has no confirmed way to reference an environment variable in this field. Treat this configuration file as sensitive, keep it out of version control, and rotate the credential if it’s ever exposed.

3. Start Goose:

        goose session

    Goose connects using the credentials you provided.

[](#use-agent)Use Goose for development tasks
---------------------------------------------

Now that Goose is connected to the CloudBees CI MCP Router, you can use the following tools and commands to accelerate your development workflow. For a list of supported tools, refer to [CloudBees CI MCP Router tool reference](/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/kiro -->

# Connect Kiro to the CloudBees CI MCP Router

Connect Kiro to the CloudBees CI MCP Router
===========================================

Kiro is an AI-powered command-line interface (CLI) tool that integrates with the CloudBees CI MCP Router through the [MCP Server plugin](/plugins/ci/mcp-server), connecting your development environment to CloudBees CI. This enables context-aware code suggestions and automation using real CloudBees CI data, so you can interact with Jenkins resources directly from your development environment.

[](#prerequisites)Prerequisites
-------------------------------

Before you begin, ensure that you have:

* The [CloudBees CI MCP Router installed](/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router).

* Configured authentication using [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth) or an [API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication).

* Kiro installed.

[](#connect-agent)Connect Kiro
------------------------------

After completing the prerequisites, connect Kiro to the CloudBees CI MCP Router using the authentication method you configured.

* [Connect with OAuth](#connect-oauth) (recommended)

* [Connect with an API token](#connect-token)

### [](#connect-oauth)Connect with OAuth

With [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), you do not need to pass credentials to the command line. You sign in once, and the CloudBees CI MCP Router handles the rest.

To connect Kiro to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Kiro is installed.

2. Run the following command to add CloudBees CI MCP Router to Kiro:

        kiro-cli mcp add --name ci-mcp-router --url <router-url>(1)

    **1**

    Replace `<router-url>` with the MCP endpoint of your CloudBees CI MCP Router: `http://localhost:9000/mcp` for a local Docker deployment, or `https://<cluster-domain>/mcp-router/mcp` for a Helm deployment.

3. Start Kiro:

        kiro-cli

    Kiro detects that the `ci-mcp-router` server requires OAuth and prompts you to authenticate.

4. Press Ctrl+y to authenticate. Kiro copies an OAuth approval URL to your clipboard.

5. Paste the URL into your browser and approve access. After you approve, Kiro reuses the session for later requests.

### [](#connect-token)Connect with an API token

Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](/docs/cloudbees-ci/latest/mcp-router/oauth), which authenticates each request individually rather than relying on a shared token.

To connect Kiro to the CloudBees CI MCP Router:

1. Open a terminal on the machine where Kiro is installed.

2. Run the following command to add CloudBees CI MCP Router to Kiro:

        kiro-cli mcp add --name ci-mcp-router --url <router-url>(1)

    **1**

    Replace `<router-url>` with the MCP endpoint of your CloudBees CI MCP Router: `http://localhost:9000/mcp` for a local Docker deployment, or `https://<cluster-domain>/mcp-router/mcp` for a Helm deployment.

3. Open the `mcp.json` configuration file the command created. For more information, refer to [Kiro MCP configuration](https://kiro.dev/docs/mcp/configuration/).

4. Add a `headers` entry to the `ci-mcp-router` server, including the encoded HTTP basic authentication credentials you generated in [Authenticate with an API token](/docs/cloudbees-ci/latest/mcp-router/token-authentication).

    The `kiro-cli mcp add` command does not provide an option to set headers, so you must add this field manually.

        {
          "mcpServers": {
            "ci-mcp-router": {
              "url": "<router-url>",(1)
              "headers": {
                "Authorization": "Basic dXNlcm5hbWU6dG9rZW4="(2)
              }
            }
          }
        }

    **1**

    This is the same `<router-url>` you specified in the `kiro-cli mcp add` command.

    **2**

    Replace `dXNlcm5hbWU6dG9rZW4=` with your actual encoded credentials.

    Passing the encoded credential directly in this command leaves it in your shell history, and storing it as plain text in your MCP configuration file leaves it exposed to any process that can read that file.

    Kiro lets you reference an environment variable in the `headers` value instead of the literal credential. Refer to [Kiro MCP configuration](https://kiro.dev/docs/mcp/configuration/) for details.

5. Save the `mcp.json` file.

6. Start Kiro:

        kiro-cli

    Kiro connects using the credentials you provided.

[](#use-agent)Use Kiro for development tasks
--------------------------------------------

Now that Kiro is connected to the CloudBees CI MCP Router, you can use the following tools and commands to accelerate your development workflow. For a list of supported tools, refer to [CloudBees CI MCP Router tool reference](/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference -->

# CloudBees CI MCP Router tool reference

CloudBees CI MCP Router tool reference
======================================

Tools available through the CloudBees CI MCP Router fall into two categories: a small set of tools specific to the CloudBees CI MCP Router itself, and a larger set forwarded dynamically from the [MCP Server plugin](/plugins/ci/mcp-server) running on each controller you can access.

Your MCP agent lists CloudBees CI MCP Router-specific tools and tools forwarded from the [MCP Server plugin](/plugins/ci/mcp-server) together, with no distinction between them. For the tools forwarded from the [MCP Server plugin](/plugins/ci/mcp-server), refer to [MCP Server plugin - Available Tools](https://plugins.jenkins.io/mcp-server/#plugin-content-available-tools).

[](#how-tools-work)How tools work
---------------------------------

When you ask your MCP agent a question, it determines which tools to call and with what parameters. You do not need to know the exact tool names. Ask in natural language.

For example:

"List the controllers I can access"

MCP agent calls `listControllers`.

"How many jobs are there?"

MCP agent calls `getJobs`.

"Who am I?"

MCP agent calls `whoAmI`, which reports the identity the CloudBees CI MCP Router is using for each controller it reaches. This can be useful for troubleshooting the OAuth or token authentication chain.

[](#router-tools)CloudBees CI MCP Router-specific tools
-------------------------------------------------------

These tools are unique to the CloudBees CI MCP Router and are not part of the [MCP Server plugin](/plugins/ci/mcp-server).

`listControllers`

Lists the controllers this operations center manages, so you can map a deployment’s topology and check controller availability before calling other tools. For each controller, it returns its name and full path, display name and description, its page in the operations center UI (`url`), its own base URL (`endpoint`), its last known Jenkins version, its lifecycle state, and a status of online, offline, or hibernated. It accepts an optional `names` array to filter by exact short name or full path (for example, `ctrl-a` or `team-a/ctrl-a`). A folder name alone matches nothing, and omitting the array returns every accessible controller.

[](#tool-access-permissions)Tool access and permissions
-------------------------------------------------------

Access to CloudBees CI MCP Router tools depends on which controllers your credentials grant access to. When a call targets multiple controllers, each controller succeeds or fails independently, so a controller you do not have permission to access returns its own access-denied result without affecting the other controllers.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/troubleshooting -->

# Troubleshoot CloudBees CI MCP Router

Troubleshoot CloudBees CI MCP Router
====================================

If you encounter problems configuring or connecting CloudBees CI MCP Router, use this guidance to identify the cause and resolve the issue.

OAuth requests are rejected after configuration

If OAuth requests are rejected after configuration, check the following common misconfigurations:

* **Issuer mismatch**: The **Trusted issuer** on the resource server and the `OAUTH_ISSUER` of the CloudBees CI MCP Router must both match the **Issuer URL** of the authorization server exactly, including `https://` and any trailing path.

* **Audience mismatch**: Each controller and the CloudBees CI MCP Router must appear in the **Allowed audiences** list of the authorization server, and the **Accepted audience** of each instance must be its own address.

* **Keys unreachable**: controllers fetch the signing keys from the issuer’s public HTTPS `/jwks` endpoint by default. If a controller genuinely cannot reach that address, set the **Internal JWKS URL** on the authorization server to an internally reachable **HTTPS** address.

If the issue persists, contact [CloudBees Support](https://support.cloudbees.com).

An OAuth signing key may be compromised

If you suspect the authorization server’s OAuth signing key material has been exposed, refer to [Force-remove a compromised OAuth signing key](/docs/cloudbees-ci/latest/mcp-router/signing-key-incident) to force-remove the compromised key from the JSON Web Key Set (JWKS) immediately, rather than waiting for scheduled rotation.

OAuth requests are failing: debug logging (UI)

If OAuth requests are failing, enable FINE-level logging for the [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) on the operations center or controller that is rejecting the request. This produces detailed bearer token validation traces, including `bearer_reject` lines when a request is passed through without a valid bearer token.

To enable debug logging in the UI:

1. In the operations center or controller, navigate to **Manage Jenkins**  **System Log**.

2. Select **\+ Add recorder**.

3. On the **New log recorder** screen, enter a name (for example, `oauth-resource`) and select **Create**.

4. Under **Loggers**, select **+Add**.

    1. For **Logger**, enter `com.cloudbees.jenkins.plugins.oauth.resource`.

    2. Set **Log level** to **FINE**.

5. Select **Save**.

    Logs are displayed in real time on the recorder page and written to the Jenkins log.

    FINE logging is verbose. Disable it once you have identified the issue.

OAuth requests are failing: debug logging (Configuration as Code)

If OAuth requests are failing, enable FINE-level logging for the [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) on the operations center or controller that is rejecting the request. This produces detailed bearer token validation traces, including `bearer_reject` lines when a request is passed through without a valid bearer token.

To enable debug logging using Configuration as Code (CasC):

1. In the CasC bundle for the operations center or controller, add the following to your `jenkins.yaml` file:

        unclassified:
          log:
            recorders:
              - name: oauth-resource
                loggers:
                  - name: com.cloudbees.jenkins.plugins.oauth.resource
                    level: FINE

2. Apply the bundle to your operations center and controllers. For more information, refer to [Update a CasC bundle](/docs/cloudbees-ci/latest/casc-update-bundle/update-bundle).

    Logs are displayed in real time on the recorder page and written to the Jenkins log.

    FINE logging is verbose. Disable it once you have identified the issue.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/signing-key-incident -->

# Force-remove a compromised OAuth signing key

Force-remove a compromised OAuth signing key
============================================

If an OAuth signing key on the operations center’s authorization server may be compromised, follow these steps to remove it immediately, without waiting for scheduled key rotation to complete. For example, `$JENKINS_HOME/secrets/master.key` on the operations center may have leaked through a host compromise, a backup leak, or a container escape, because that key decrypts the signing key at rest.

`master.key` is a product-wide CloudBees CI root secret. Protecting it through host hardening, backup handling, and container isolation is outside the scope of this procedure and of the CloudBees CI MCP Router. This procedure covers only the OAuth signing key.

[](#signing-key-rotation)Signing key rotation
---------------------------------------------

The authorization server holds at most two signing keys:

* **Active key**: Signs new tokens.

* **Retiring key**: Stays published during a short overlap window so that tokens issued before a rotation still validate.

The key material is stored, encrypted, in `$JENKINS_HOME/cloudbees-oauth-server/signing-keys.xml` on the operations center.

Two behaviors make incident response necessary:

* The operations center publishes public keys from the JSON Web Key Set (JWKS) endpoint (`/oauth-server/jwks`), and controllers cache the key set with a lifetime of up to 300 seconds (five minutes).

* Scheduled rotation only drops the retiring key after the overlap window elapses. It does not evict a key on demand.

A single rotation does not remove a compromised key. Rotating once demotes the current active key to the retiring slot, where it stays published in the JWKS and continues to validate forged tokens. You must rotate twice to evict it; the second rotation overwrites the retiring slot with a freshly generated key.

[](#remove-compromised-key)Remove the compromised key
-----------------------------------------------------

The following steps rotate the signing key twice, which evicts the compromised key from the JWKS regardless of whether it was the active or retiring key.

You need **Overall/Administer** permission on the operations center to complete this procedure.

To remove the compromised key:

1. Fetch the JWKS from the authorization server and note the `kid` values currently published:

        curl -s https://oc.example.com/oauth-server/jwks | jq '.keys[].kid'

    The active `kid` is also written to the operations center log on every rotation (`Signing key rotated. Active kid=…​`). Confirm which `kid` corresponds to the compromised key before continuing.

2. On the operations center, navigate to **Manage Jenkins**  **Script Console** and run the following script. It rotates twice, which evicts the compromised key regardless of whether it was the active or the retiring key:

        import com.cloudbees.jenkins.plugins.oauth.server.SigningKeys
        
        def keys = SigningKeys.get()
        println "before: " + keys.allPublicJwks()*.getId()
        
        // First rotation: the compromised active key becomes the retiring key (still published),
        // and a fresh active key is generated.
        keys.rotate()
        // Second rotation: overwrites the retiring slot, evicting the compromised key entirely.
        keys.rotate()
        
        println "after:  " + keys.allPublicJwks()*.getId()

    The compromised `kid` must not appear in the `after:` list. Both listed keys should be freshly generated.

    If the operations center Script Console is unavailable, stop the operations center, delete `$JENKINS_HOME/cloudbees-oauth-server/signing-keys.xml`, and restart. A new active key is generated on startup. This invalidates all previously issued tokens, not only forged ones.

3. Fetch the JWKS again and confirm the compromised `kid` no longer appears:

        curl -s https://oc.example.com/oauth-server/jwks | jq '.keys[].kid'

    New tokens are already signed with the fresh active key. Any token still bearing the compromised `kid` now fails validation at the authorization server with an `unknown kid` error.

[](#key-rotation-propagation)Key rotation propagation
-----------------------------------------------------

The authorization server stops advertising the compromised key immediately. Each controller caches the JWKS for up to 300 seconds (five minutes), so the change propagates across the fleet within one cache lifetime. A controller that receives a token with an unrecognized `kid` refreshes its cached key set sooner (subject to a short refetch cooldown), so in practice most controllers pick up the new key set within seconds of the next request.

[](#post-incident-followup)Post-incident follow-up
--------------------------------------------------

After removing the key, take the following steps to investigate and prevent future exposure.

* Investigate what exposed the key material. If `master.key` may have leaked, treat it as a CloudBees CI-wide incident.

* Revoke affected users' grants and refresh tokens if their credentials may also be compromised.

For other OAuth issues, refer to [Troubleshoot CloudBees CI MCP Router](/docs/cloudbees-ci/latest/mcp-router/troubleshooting).
