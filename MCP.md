# CloudBees CI MCP Router Documentation

Collected 2026-10-29 from <https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/> and its sub-pages.
Page text was retrieved through the CloudBees docs search index (`librarian-doc`), which serves `docs.beescloud.com` content for the same paths; it was not scraped from `docs.cloudbees.com` directly. Page bodies are unmodified, but relative links are left as-is.

Helm values in **Enable OAuth with Helm** were cross-checked against the `cloudbees-core` chart on Artifact Hub (<https://artifacthub.io/packages/helm/cloudbees/cloudbees-core>), chart version 3.38435.0+980594e799d5 (CloudBees CI 2.580.2.38434). The `McpRouter.privateKeyJwt`, `McpRouter.extraEnv`, `McpRouter.ocInternalUrl`, and `McpRouter.javaOpts` entries were expanded from that chart's parameter table.

---

## Table of Contents

1. [Quick Start: Add MCP Server](#quick-start-add-mcp-server)
2. [Architecture](#architecture)
   - [Components (Generic)](#components-generic)
   - [OAuth Flow (Generic)](#oauth-flow-generic)
3. [This Environment](#this-environment)
   - [Topology](#topology)
   - [Token Exchange Sequence](#token-exchange-sequence)
   - [Install Parameters](#install)
   - [Operations Center Bundle (`casc/cjoc`)](#operations-center-bundle-cascjoc-bundle-id-jenkins)
   - [Managed Controllers](#managed-controllers-cascjoccontrollers)
   - [Controller Bundle (`casc/controller-base`)](#controller-bundle-casccontroller-base-bundle-id-controller)
   - [MCP Test Items](#mcp-test-items-controller-basemcpmcp-test-itemsyaml)
   - [Allowed Audiences](#allowed-audiences-the-part-that-breaks-token-exchange)
   - [Controller Status](#controller-status)
   - [Known Inconsistencies](#known-inconsistencies-in-the-bundles)
   - [Connect Claude Code (Local Setup)](#connect-claude-code-local-setup)
   - [Troubleshooting Observed in this Environment](#troubleshooting-seen-here)
4. [Installation and Deployment](#installation-and-deployment)
   - [Prerequisites](#installation-prerequisites)
   - [Download Image](#download-the-cloudbees-ci-mcp-router-image)
   - [Verify Docker Image Signature](#verify-the-docker-image-signature)
   - [Deploy the CloudBees CI MCP Router](#deploy-the-cloudbees-ci-mcp-router)
     - [Deploy with Docker](#deploy-with-docker)
     - [Deploy in Kubernetes](#deploy-in-kubernetes)
5. [Rate Limiting](#rate-limiting)
   - [How Rate Limiting Works](#how-rate-limiting-works)
   - [Enable Rate Limiting](#enable-rate-limiting)
   - [Rate Limiting Environment Variables](#rate-limiting-environment-variables)
   - [Security Considerations](#rate-limiting-security-considerations)
6. [Authentication Configuration](#authentication-configuration)
   - [Enable OAuth Authentication](#enable-oauth-authentication)
     - [Prerequisites](#oauth-prerequisites)
     - [Pre-seeded OAuth Clients](#pre-seeded-oauth-clients)
     - [Enable OAuth with Helm](#enable-oauth-with-helm)
     - [(Optional) Tune the Helm Configuration](#optional-tune-the-helm-configuration)
     - [Manually Configure OAuth](#manually-configure-oauth)
     - [Configure Using Configuration as Code (CasC)](#configure-using-configuration-as-code-casc)
     - [Configure CloudBees CI MCP Router Container](#configure-the-cloudbees-ci-mcp-router-container)
     - [Verify OAuth is Working](#verify-oauth-is-working)
   - [Authenticate with an API Token](#authenticate-with-an-api-token)
     - [Prerequisites](#api-token-prerequisites)
     - [Generate an API Token](#generate-an-api-token)
     - [Encode Credentials for HTTP Basic Authentication](#encode-credentials-for-http-basic-authentication)
7. [Connecting MCP Agents](#connecting-mcp-agents)
   - [Connect Claude Code](#connect-claude-code)
   - [Connect GitHub Copilot](#connect-github-copilot)
   - [Connect Goose](#connect-goose)
   - [Connect Kiro](#connect-kiro)
8. [Tool Reference](#tool-reference)
   - [How Tools Work](#how-tools-work)
   - [Router-Specific Tools (`listControllers`)](#router-specific-tools)
   - [Tool Access and Permissions](#tool-access-and-permissions)
9. [Troubleshooting](#troubleshooting)
   - [Common Misconfigurations](#common-misconfigurations)
   - [Debug Logging (UI)](#debug-logging-ui)
   - [Debug Logging (Configuration as Code)](#debug-logging-configuration-as-code)
10. [Incident Response: Force-Remove a Compromised OAuth Signing Key](#incident-response-force-remove-a-compromised-oauth-signing-key)
    - [Signing Key Rotation Concept](#signing-key-rotation)
    - [Remove the Compromised Key](#remove-the-compromised-key)
    - [Key Rotation Propagation](#key-rotation-propagation)
    - [Post-Incident Follow-Up](#post-incident-follow-up)

---

## Quick Start: Add MCP Server

```bash
claude mcp remove ci-mcp-router
claude mcp add --transport http --client-id ci-mcp-client \
  --callback-port 8123 ci-mcp-router https://ci.example.com/mcp-router/mcp
```

---

## Architecture

These diagrams sketch how the pieces in the pages below fit together. They're an overview, not upstream documentation.

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

---

## This Environment

Derived from the CasC bundles in `casc/cjoc` (bundle id `jenkins`, version 6) and `casc/controller-base` (bundle id `controller`, version 3), the managed controller definitions in `casc/cjoc/controllers/`, `eks/eksctl/05-installCloudBees.sh`, and a live `listControllers` call through the router on 2026-11-06. Only the MCP-related parts are covered. Client secrets, the GitHub token and the license key are not in the bundles and are not reproduced here. Do not commit secrets exported from a running OC.

An earlier version of this section (2026-10-29) was based on exports in `casc/export/`. Where the bundles and that export differ, the bundles show what is declared and the running OC shows what is enforced (not re-verified here).

### Topology

```mermaid
flowchart LR
    Agent["Claude Code<br/>client-id ci-mcp-client (PKCE)"]

    subgraph EKS["EKS cluster, namespace cbci"]
        GW["Gateway API: cbci-gateway<br/>ci.example.com"]
        R["MCP Router<br/>upstreamMode AUTO<br/>500m CPU, 1Gi"]

        subgraph OCS["Operations center /cjoc"]
            OC["cjoc<br/>RBAC: cloudBeesRoleBasedAccessControl<br/>plugins: mcp-server, cloudbees-oauth-server,<br/>cloudbees-oauth-resource, oauth-credentials"]
            AS["OAuth server /cjoc/oauth-server<br/>issuer, JWKS, token exchange"]
        end

        subgraph ON["Bundle-managed controllers online (MCP reachable)"]
            C1["controller1<br/>bundle: controller-base (SCM)"]
            C3["controller3<br/>bundle: controller-base (SCM)"]
        end

        subgraph OFF["Bundle-managed controllers offline"]
            C2["controller2 (DEPROVISIONED)<br/>bundle: external bundle service"]
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

### Operations center bundle (`casc/cjoc`, bundle id `jenkins`)

MCP settings are split into `mcp/` files referenced from `casc/cjoc/bundle.yaml`: `mcp/mcp-jenkins.yaml` (jcasc), `mcp/mcp-credentials.yaml` (jcasc), `mcp/mcp-plugins.yaml` (plugins) and `mcp/mcp-variables.yaml` (variables).

| Area | Setting |
| --- | --- |
| Plugins | `mcp-server`, `cloudbees-oauth-server`, `cloudbees-oauth-resource` (`mcp/mcp-plugins.yaml`); `oauth-credentials` is declared in the base `plugins.yaml` |
| OAuth server | issuer `https://${GATEWAY_DOMAIN}/cjoc/oauth-server`; `internalJwksUrl: http://cjoc/cjoc/oauth-server/jwks`; access token TTL 600s; exchanged token TTL 300s; DCR disabled; `autoApproveSeededClients: true`; `enforceTrustedIssuer: false`; client assertion skew 30s / max lifetime 300s; JWKS cache 300s; idle DCR eviction on (90 days); `rootRegisterCompat: false` |
| Global `allowedAudiences` | `"${mcp_audiences}"`, defined in `mcp/mcp-variables.yaml` (see below) |
| OAuth resource server | `trustedIssuer` = the issuer above; `filterMode: AUTO`; `protectedPaths: /mcp-server/*`; clock skew 60s; JWKS cache 300s |
| Client `cloudbees-mcp-router` | `jenkinsOAuthClient`, scope `SYSTEM`, confidential, `grantTokenExchange: true`, `CLIENT_SECRET_BASIC`, `audience: https://${GATEWAY_DOMAIN}/mcp-router`. **No per-client `allowedAudiences` and no secret declared in the bundle** |
| Client `ci-mcp-client` | `jenkinsOAuthClient`, scope `SYSTEM`, public (`tokenEndpointAuthMethod: NONE`), auth-code + refresh, PKCE required, `audience: https://${GATEWAY_DOMAIN}/mcp-router`, redirect URIs `http://127.0.0.1/callback`, `http://[::1]/callback`, `http://localhost/callback` |
| Controller items | `controllers/controller1.yaml`, `controller2-externalbundleservice.yaml`, `controller3.yaml` (below); `removeStrategy`: `rbac: SYNC`, `items: NONE` |

Bundle-source polling, provisioning (cluster endpoint, Gateway exposure, storage class) and cluster operations aren't MCP-related, so this section skips them.

The credentials fragment in `mcp/mcp-credentials.yaml` is a second `credentials.system.domainCredentials` entry next to `credentials.yaml` (`gh-user-token`). The file itself says the merge has to be validated on the OC.

### Managed controllers (`casc/cjoc/controllers/`)

| Controller | Item file | Controller bundle | MCP config source | Live status (2026-11-06) | State |
| --- | --- | --- | --- | --- | --- |
| controller1 | `controller1.yaml` | SCM: `${CASC_SCM_BRANCH}/controller-base` | `controller-base/mcp/*` | online, 2.580.2.38435 | APPROVED |
| controller2 | `controller2-externalbundleservice.yaml` | External bundle service (`cascBundleServiceBundle`) | Not from this repo (see caveat) | offline | DEPROVISIONED |
| controller3 | `controller3.yaml` | SCM: `${CASC_SCM_BRANCH}/controller-base` | `controller-base/mcp/*` | online, 2.580.2.38435 | APPROVED |

All three: Kubernetes, 1 CPU, 3072 MB, 50 GB disk, `sharedConfigurationOptOut.optOut: false`. Status was read through the router's `listControllers` (filtered by name). An unfiltered `listControllers` timed out on the same day, consistent with other controllers on the OC being offline; the full controller set on the running OC was not re-read.

> **Caveat (controller2):** it uses an external CasC bundle service bundle, not `controller-base`. The MCP plugins and `oauthResourceServer` settings below apply to it only if that external bundle replicates them. It is currently DEPROVISIONED, so this is untested.

### Controller bundle (`casc/controller-base`, bundle id `controller`)

MCP settings live in `mcp/mcp-jenkins.yaml`, `mcp/mcp-plugins.yaml` and `mcp/mcp-test-items.yaml`.

| Area | Setting |
| --- | --- |
| Plugins | `mcp-server`, `cloudbees-oauth-resource` (`mcp/mcp-plugins.yaml`). `cloudbees-oauth-server` is not installed (operations center only) |
| OAuth resource server | `trustedIssuer: https://${GATEWAY_DOMAIN}/cjoc/oauth-server` (pinned in the bundle); `jwksUrl: http://cjoc/cjoc/oauth-server/jwks` (in-cluster, avoids hairpin NAT); `filterMode: AUTO`; `protectedPaths: /mcp-server/*`; clock skew 60s; JWKS cache 300s |
| `oauthAuthorizationServer` block | Present in `mcp/mcp-jenkins.yaml` with tuning values only (`autoApproveSeededClients: false`, `dcrEnabled: false`, `enforceTrustedIssuer: false`, TTLs). Without the server plugin on the controller this block is likely inert (ASSUMPTION, not verified); the authoritative server and clients live on the OC |
| Items | `mcp/mcp-test-items.yaml`: folder `mcp-test-pipeline` (see below) |

### MCP test items (`controller-base/mcp/mcp-test-items.yaml`)

Folder `mcp-test-pipeline` ("MCP test pipeline") with group `developers` (user `dev1`, role `develop`, granted at `current`), holding simulation pipelines for exercising MCP build and diagnostic tools. Jobs use the Kubernetes agent plugin with `alpine` images. Because `controller1` and `controller3` share this bundle, each gets the same jobs, which allows "same error across controllers" tests.

| Job | Simulates |
| --- | --- |
| `01-always-fail` | Always fails with the same registry 401 error |
| `02-flaky` | Fails about 40% of the time, cron every 10 min |
| `03-slow-pod-start` | Init container delays the agent by about 90s |
| `04-queue-pressure` | `PODS` (default 8) parallel pods, each requesting 1 CPU / 1Gi |
| `06-bad-image` | Non-existent image tag, 3 min timeout |
| `07-risky-patterns` | Privileged container, Docker socket mount, `latest` tag, `curl \| sh` text (echoed only). Pod Security Admission may reject the pod |

`05-oomkilled` is present but commented out. Validate these in a test environment first: `02-flaky` runs on a schedule and `04-queue-pressure` consumes cluster capacity.

### Allowed audiences (the part that breaks token exchange)

The bundle declares one allow-list: the global `security.oauthAuthorizationServer.allowedAudiences`, set from the `mcp_audiences` variable in `casc/cjoc/mcp/mcp-variables.yaml` (one `https://${GATEWAY_DOMAIN}/<name>` per line):

| Entry | In `casc/cjoc/controllers/`? |
| --- | --- |
| `cjoc` | n/a (operations center) |
| `controller1`, `controller2`, `controller3` | yes |
| `folder-dev1-controllers-folder-controller1`, `folder-dev1-controllers-folder-controller2`, `hahs`, `plugins-casc-uc`, `plugable-storage`, `testnodegroup`, `workshop` | no |

**Per-client lists are no longer declared.** The 2026-10-29 export had `allowedAudiences` on `cloudbees-mcp-router`; `mcp-credentials.yaml` omits it. ASSUMPTION: whether the running OC still enforces a per-client list, and what an empty one means, was not verified. If the `invalid_target ... allowedAudiences for client_id=cloudbees-mcp-router` error reappears, check the client in the OC UI first.

The router requests every controller audience at once (exchange 2 above), taken from the OC controller list. If one controller on the OC is missing from the global list, the whole call fails. The seven entries without a bundle item are there so controllers that still exist on the OC keep working. Keep the list in sync with the controllers actually on the OC, and keep it in CasC so a bundle reload does not revert a UI edit.

### Controller status

See the table under [Managed controllers](#managed-controllers-cascjoccontrollers). Offline controllers return empty results through the router, and an unfiltered call can time out waiting on them. Use `controllerNames` to target online controllers.

### Known inconsistencies in the bundles

| Where | Issue |
| --- | --- |
| `cjoc/mcp/mcp-jenkins.yaml` header | Says audiences come from an env var `MCP_ALLOWED_AUDIENCES`; the file actually uses the CasC variable `mcp_audiences` from `mcp/mcp-variables.yaml`. The same header and the other `mcp/` files reference `eks/eksctl/MCP.md`, but this document is `MCP.md` at the repo root |
| `controller-base/mcp/mcp-jenkins.yaml` header | Says `trustedIssuer` is not set and is seeded by the OC; the file does set it (and `jwksUrl`) |
| `controller-base/mcp/mcp-jenkins.yaml` | Contains an `oauthAuthorizationServer` block although the server plugin is not installed on controllers |
| `cjoc/mcp/mcp-credentials.yaml` | Second `domainCredentials` fragment; merge with `credentials.yaml` is flagged as unvalidated in the file |
| `cjoc/mcp/mcp-variables.yaml` | Lists 7 audiences with no controller item in `casc/cjoc/controllers/` |
| `cjoc/mcp/mcp-credentials.yaml` | No per-client `allowedAudiences` (differs from the earlier export) |

### Connect Claude Code (Local Setup)

```bash
claude mcp add ci-mcp-router https://<domain>/mcp-router/mcp --transport http --client-id ci-mcp-client
```

Then run `/mcp`, select `ci-mcp-router`, and approve in the browser.

### Troubleshooting seen here

| Symptom | Cause | Fix |
| --- | --- | --- |
| `/mcp` fails with HTTP 504, router log `token-exchange failed ... invalid_target ... allowedAudiences for client_id=cloudbees-mcp-router` | `https://<domain>/cjoc` missing from the client's allow-list (seen when the per-client list was set; the bundle no longer declares one, see Allowed audiences) | Check the `cloudbees-mcp-router` client on the OC, and the global list |
| Tools return `audience not in configured allow-list: .../controller2` | Controller audiences missing from the global `allowedAudiences` | Add all controller audiences to `mcp_audiences` in `casc/cjoc/mcp/mcp-variables.yaml` (and reload the bundle) |
| Router warns `/cjoc/mcp-server/stateless returned 404`, `listControllers` unavailable | `mcp-server` plugin not installed on the OC at router start | Install the plugin, then reconnect with `/mcp` (the router retries per session) |
| Empty job lists, or unfiltered calls time out | Target controllers offline, deprovisioned or hibernating | Start them, or pass `controllerNames` |
| `getJobs` on the OC (`operations-center`) returns `[]` | OC MCP tools cover topology (`listControllers`), not job listing | Use the CJOC UI or REST API for OC items and cluster operations |
| Router logs `Invalid MCP protocol header: 2026-07-28` (HTTP 400) then continues | Client sends a newer protocol version than the router's Quarkus MCP extension supports | Harmless fallback; update the router image when available |

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/ci-mcp-router -->

## Installation and Deployment

To install the CloudBees CI MCP Router, first install the [MCP Server plugin](/plugins/ci/mcp-server) on your controllers, and then deploy the CloudBees CI MCP Router as a Docker container or in a Kubernetes cluster.

* If you already deploy CloudBees CI on Kubernetes with the `cloudbees-core` Helm chart and plan to use OAuth, you can deploy and configure the CloudBees CI MCP Router using Helm without following manual deployment steps. For more information, refer to [Enable OAuth with Helm](#enable-oauth-with-helm).
* To protect the CloudBees CI MCP Router from request floods and runaway agent loops, refer to [Rate Limiting](#rate-limiting).

### Installation Prerequisites

Before you begin, ensure that you have the following:

* CloudBees CI version `2.541.2.35785` or later.
* The [MCP Server plugin](/plugins/ci/mcp-server), version `0.148.v6b_c057f27738` or later, installed on one or more controllers.

### Download the CloudBees CI MCP Router Image

To use the CloudBees CI MCP Router, you must have the container image available locally for Docker or in your Kubernetes cluster.

#### Download for Docker

For local Docker use, manually download the CloudBees CI MCP Router image from [Docker Hub](https://hub.docker.com/r/cloudbees/ci-mcp-router):

```bash
docker pull cloudbees/ci-mcp-router:<my-tag>
```

> **Note:** Replace `<my-tag>` with the specific version or digest you intend to use.

#### Download for Kubernetes

For Kubernetes deployments, the image is pulled automatically by the cluster when a pod is created. To verify the image before use (recommended for production or regulated environments), pre-pull it to a node or private registry and verify as described below.

### Verify the Docker Image Signature

The CloudBees CI MCP Router Docker images are signed so you can verify their origin and authenticity. This helps protect against "man-in-the-middle" attacks and other forms of image tampering.

After the image is present locally (either pulled manually or by Kubernetes), verify its signature to ensure authenticity and integrity.

1. Download the [Cosign verification tool](https://github.com/sigstore/cosign#installation). Cosign is part of Sigstore, a suite of projects designed to simplify software signing.
2. Run one of the following commands to verify the authenticity of a specific CloudBees CI MCP Router Docker image:

   - **Verify by digest:**
     ```bash
     cosign verify --key https://cdn.cloudbees.com/keyring/cloudbees.pub cloudbees/ci-mcp-router@sha256:<my-digest>
     ```
     *(Replace `<my-digest>` with the specific SHA-256 digest of the image, such as `abc123def456…`.)*

   - **Verify by tag:**
     ```bash
     cosign verify --key https://cdn.cloudbees.com/keyring/cloudbees.pub cloudbees/ci-mcp-router:<my-tag>
     ```
     *(Replace `<my-tag>` with the specific tag of the image, such as `latest` or a version number like `1.2.3`.)*

Cosign returns a message indicating whether the images are authentic. An exit code of `0` indicates that the images are authentic. If the images are not validated as authentic, contact [CloudBees Support](https://support.cloudbees.com).

### Deploy the CloudBees CI MCP Router

Choose one of the following methods based on your environment:

> [!NOTE]
> **OpenID Connect (OIDC) configurations**
>
> If you use API token authentication and your operations center is configured to use OIDC, ensure the **Allow access using a Jenkins API token without an OIDC Session?** option is selected in the operations center. This allows API tokens to work without requiring a browser session.
>
> If this option is not selected, you must first sign in to the operations center via a browser before deploying the CloudBees CI MCP Router, so your credentials are recognized as valid. If your browser session expires, sign in to the operations center again to refresh your session.
>
> Before using this configuration, review and understand the security implications for your environment. If you have any questions or concerns, contact [CloudBees Support](https://support.cloudbees.com).

#### Deploy with Docker

After verifying the image, you can run the CloudBees CI MCP Router locally using Docker:

```bash
docker run -p 9000:9000 \
  -e OC_URL=<my-oc-url> \
  -e MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL=<my-ttl> \
  -e MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE=<my-mode> \
  cloudbees/ci-mcp-router:<my-tag>
```

**Parameters:**
- `OC_URL`: Replace `<my-oc-url>` with the URL for your operations center.
- `MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL`: *(Optional)* Controls how long the CloudBees CI MCP Router caches the list of controllers from the operations center (default: `1H`). Decrease to detect newly provisioned controllers or controllers waking from hibernation faster; increase to reduce operations center load. Use suffixes `H` (hours), `M` (minutes), or `S` (seconds); for example, `1S` effectively disables caching.
- `MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE`: *(Optional)* Controls how access tokens are scoped when the router calls controllers (default: `FLEET`). `FLEET` generates one token covering all controllers (one authorization server round-trip); `PER_TARGET` generates one token per controller (one round-trip per controller). Use `PER_TARGET` when controllers are operated by different teams, to limit the scope of access if a controller is compromised.
- `<my-tag>`: Replace with the specific tag or digest you have verified. Clients connect to the mapped external port (e.g. `http://localhost:9000/mcp`).

#### Deploy in Kubernetes

After verifying the image, you can reference it in your Kubernetes manifests. The following excerpt shows the relevant section of the deployment manifest:

```yaml
containers:
  - name: <my-app>
    image: cloudbees/ci-mcp-router:my-tag
    ports:
      - containerPort: 9000
    env:
      - name: JAVA_TOOL_OPTIONS
        value: "-Doc.url=<my-oc-url>"
      - name: MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL
        value: "<my-ttl>"
      - name: MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE
        value: "<my-mode>"
```

**Parameters:**
- `<my-app>`: Container name.
- `my-tag`: Specific tag or digest already verified (e.g. `1.2.3` or `@sha256:abc123…`). For security and reproducibility, do not use `latest`.
- `containerPort: 9000`: Default internal port. Map any host or cluster port as needed; clients connect to the mapped port (e.g. `http://localhost:9000/mcp`).
- `-Doc.url=<my-oc-url>`: Operations center URL.
- `MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL`: Controller list cache TTL (default: `1H`).
- `MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE`: Scoping mode (`FLEET` or `PER_TARGET`, default: `FLEET`).

In `FLEET` mode (the default), a compromised controller holds a token that is accepted by every other controller. When controllers are operated by different teams, set `MCP_AUTH_UPSTREAM_TOKEN_EXCHANGE_MODE=PER_TARGET` to scope each token to a single controller.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/rate-limiting -->

## Rate Limiting

The CloudBees CI MCP Router can cap how quickly a single caller reaches its `/mcp` endpoint, so that one misconfigured client or a runaway agent loop cannot flood the CloudBees CI MCP Router and overwhelm the controllers behind it. Rate limiting is disabled by default. Enable it when you are ready to protect a shared or public deployment.

### How Rate Limiting Works

Rate limiting gives each caller its own allowance of requests over a rolling window of time. Each request consumes one unit of the allowance, which refills steadily as the window progresses (a per-identity token bucket).

While a caller stays within its allowance, its requests pass straight through without being rate limited. Once the allowance runs out, further requests receive an `HTTP 429 Too Many Requests` response with a `Retry-After` header that tells the client how long to wait before trying again.

The check runs at the very front of the `/mcp` endpoint, before any message is parsed, so it applies to the whole MCP conversation, including `initialize`, `tools/list`, and `tools/call`.

The CloudBees CI MCP Router identifies each caller in one of two ways:
* **Authenticated callers** are keyed by a hash of their `Authorization` header, so the raw credential is never stored, and each token or user gets its own allowance.
* **Anonymous callers** (with no `Authorization` header) are keyed by their client IP address, so one anonymous flood cannot lock everyone else out.

### Enable Rate Limiting

To turn on rate limiting, set `MCP_RATE_LIMIT_ENABLED` to `true` on the CloudBees CI MCP Router when you [deploy it](#deploy-the-cloudbees-ci-mcp-router). The remaining variables are optional; they refine the limit and take the defaults shown below.

If you deploy the CloudBees CI MCP Router with the `cloudbees-core` Helm chart, set these variables using `McpRouter.extraEnv` instead.

Before you enable it, watch normal traffic for a while and pick a ceiling that leaves legitimate agents comfortable headroom. A good starting point is roughly twice your observed peak, which stops abuse without throttling healthy clients.

### Rate Limiting Environment Variables

| Environment variable | Possible values | Description |
| --- | --- | --- |
| `MCP_RATE_LIMIT_ENABLED` | `true` or `false`<br/>*(default: `false`)* | The master switch. Set it to `true` to enforce rate limiting. |
| `MCP_RATE_LIMIT_PERMITS` | Positive whole number<br/>*(default: `120`)* | The maximum number of requests each caller can make within one window. |
| `MCP_RATE_LIMIT_WINDOW` | Time string with `H`, `M`, or `S`<br/>*(default: `1M`)* | The window over which each caller’s allowance refills (e.g. `1M` or `30S`). |
| `MCP_RATE_LIMIT_MAX_BUCKETS` | Positive whole number<br/>*(default: `100000`)* | The maximum number of distinct callers tracked at once. When reached, the limiter evicts the least recently seen caller, capping memory usage. |
| `MCP_RATE_LIMIT_TRUST_FORWARDED_FOR` | `true` or `false`<br/>*(default: `false`)* | Whether to trust the `X-Forwarded-For` header when keying anonymous callers by IP address. Leave disabled unless a trusted proxy sets the header. |

With the defaults, each caller is allowed 120 requests per minute.

### Rate Limiting Security Considerations

Rate limiting is a protective control, so keep the following in mind when you configure it:

* Enable `MCP_RATE_LIMIT_TRUST_FORWARDED_FOR` only when a trusted ingress or load balancer sets the `X-Forwarded-For` header. Clients can forge that header, so if the CloudBees CI MCP Router is directly reachable, a caller could dodge the limit by sending a different value on every request. When the setting is disabled (the default), anonymous callers are keyed by the IP address of their direct connection instead.
* Rate limiting protects availability, not access. It limits how often a caller can reach the CloudBees CI MCP Router, but it does not authenticate or authorize anyone, so keep [OAuth](#enable-oauth-authentication) or another authentication method in place as well.
* Authenticated callers are keyed by a hash of their `Authorization` header, so raw tokens and passwords are never stored. `MCP_RATE_LIMIT_MAX_BUCKETS` also caps how many callers are tracked at once and evicts the least recently seen when the cap is reached, so a flood of ever-changing identities cannot grow the limiter’s memory without bound.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/authenticate -->

## Authentication Configuration

The CloudBees CI MCP Router supports two ways to authenticate to CloudBees CI: **OAuth** and **API token**. OAuth is recommended because each request carries the identity of the user or tool that made it. The CloudBees CI MCP Router stores only short-lived tokens scoped to the controllers it needs to access, rather than relying on a single shared token.

Choose the method that fits your environment:
* [Enable OAuth authentication for the CloudBees CI MCP Router](#enable-oauth-authentication) (recommended)
* [Authenticate with an API token](#authenticate-with-an-api-token)

> [!WARNING]
> Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](#enable-oauth-authentication), which authenticates each request individually rather than relying on a shared token.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/oauth -->

### Enable OAuth Authentication

OAuth is the recommended way for the CloudBees CI MCP Router to authenticate to CloudBees CI. Rather than relying on one shared token, each request carries the identity of the person or tool that made it, and the CloudBees CI MCP Router holds only short-lived tokens scoped to the controllers it needs to reach.

OAuth uses the following components:
* An MCP client (such as Claude Code or GitHub Copilot) signs in once and sends an OAuth token to the CloudBees CI MCP Router.
* The CloudBees CI MCP Router exchanges that token for a short-lived token scoped to the controller it needs to reach, then forwards the request.
* The controller validates the token and runs the request as the signed-in user.

Review the [Prerequisites](#oauth-prerequisites) and [Pre-seeded OAuth clients](#pre-seeded-oauth-clients), and then choose one of the following methods to enable OAuth:
* [Enable OAuth with Helm](#enable-oauth-with-helm)
* [Manually configure OAuth](#manually-configure-oauth)

#### OAuth Prerequisites

Before you begin, ensure that you have the following:

* The **[CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource)**, installed on the operations center and on every controller that should accept OAuth, and each instance restarted after installation.
  > If your controllers are connected to the operations center, you do not need to configure each controller manually. When a controller connects to the operations center, it is automatically configured with the authorization server to trust.
* The **[CloudBees OAuth Authorization Server plugin](/plugins/ci/cloudbees-oauth-server)**, installed on the operations center and the instance restarted after installation.
* The CloudBees CI MCP Router [installed and running](#installation-and-deployment).

#### Pre-seeded OAuth Clients

The authorization server ships with two pre-seeded OAuth clients, so no client registration is required to connect an MCP agent:

* `cloudbees-mcp-router`: A confidential client, using the token-exchange grant, that the CloudBees CI MCP Router uses to exchange a user token for a controller-scoped token.
* `ci-mcp-client`: A public client, using [Proof Key for Code Exchange (PKCE)](https://oauth.net/2/pkce/), that MCP agents such as Claude Code use to sign in. Select it with the `--client-id ci-mcp-client` flag when you connect an agent.

Because these two clients are pre-seeded, an MCP agent using `ci-mcp-client` connects without needing to register first. On first use, you are asked to approve the client’s access, unless an administrator has enabled **Auto-approve seeded clients** on the authorization server.

Dynamic client registration (DCR) is disabled by default. Requests to the `/oauth-server/register` endpoint return a `403` error unless you re-enable DCR in the **CloudBees OAuth Authorization Server** configuration, or by setting `dcrEnabled: true` in CasC. Re-enable it only for environments that need self-service registration, such as test clusters or the MCP Inspector. Any client you create manually still prompts for consent on first use.

#### Enable OAuth with Helm

If you already deploy CloudBees CI with the `cloudbees-core` Helm chart, you can deploy the CloudBees CI MCP Router and enable OAuth together by adding the following values:

1. Add the following to your Helm values:

   ```yaml
   OperationsCenter:
     OAuthServer:
       Enabled: true

   McpRouter:
     enabled: true
     upstreamMode: AUTO
   ```

   - `OperationsCenter.OAuthServer.Enabled: true`: Turns on the authorization server and its discovery endpoints.
   - `McpRouter.enabled: true`: Deploys the CloudBees CI MCP Router as part of the chart. Omit if you already deployed manually.
   - `McpRouter.upstreamMode: AUTO`: `AUTO` accepts both OAuth bearer tokens and existing `Authorization` headers (such as Basic or API token), which is recommended during migration. Update to `OAUTH_ONLY` after every controller has the Resource Server plugin installed and configured.

2. Apply the values:

   ```bash
   helm upgrade cloudbees-core cloudbees/cloudbees-core --reset-then-reuse-values \
     --set OperationsCenter.OAuthServer.Enabled=true \
     --set McpRouter.enabled=true
   ```

The chart automatically:
* Configures the authorization server with the addresses allowed to receive tokens (the CloudBees CI MCP Router and the controllers).
* Configures the operations center and controllers with the authorization server to trust.
* Exposes the OAuth discovery endpoints so that MCP clients can locate them.
* Runs the CloudBees CI MCP Router under a dedicated Kubernetes service account and grants it a projected token (audience `cjoc`) that the authorization server validates to authenticate token-exchange requests; no shared secret is required.

#### (Optional) Tune the Helm Configuration

The values described above are sufficient for most deployments. The following values let you tune the authorization server and the CloudBees CI MCP Router when defaults do not suit your environment.

##### Tune Authorization Server Values

| Value | Description |
| --- | --- |
| `OperationsCenter.OAuthServer.Enabled` | Renders the OAuth discovery endpoints and configuration that seeds the [CloudBees OAuth Authorization Server plugin](/plugins/ci/cloudbees-oauth-server) and [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) on every operations center start. Grants the CloudBees CI MCP Router a projected service account token to authenticate to the authorization server. Set to `true` when the authorization server plugin is installed on the operations center.<br/><br/>**Default:** `false` |
| `OperationsCenter.OAuthServer.RouterAudience` | Public address of the CloudBees CI MCP Router that the authorization server expects in the `aud` claim of exchanged tokens. Ignored when `McpRouter.enabled` is `true`, because the chart then derives the audience from the cluster URL. Set it only for a CloudBees CI MCP Router that runs outside the cluster.<br/><br/>**Default:** `http://localhost:9000` |

##### Tune CloudBees CI MCP Router Deployment Values

| Value | Description |
| --- | --- |
| `McpRouter.enabled` | Set to `true` to deploy the CloudBees CI MCP Router as part of the chart.<br/><br/>**Default:** `false` |
| `McpRouter.upstreamMode` | Authentication mode forwarded to controllers:<br/>• `AUTO`: Exchanges a validated OAuth bearer token for a controller-scoped token, and forwards any other `Authorization` header (such as Basic or API token) verbatim.<br/>• `OAUTH_ONLY`: Requires an OAuth bearer token and rejects any other request.<br/><br/>Use `AUTO` while migrating, then switch to `OAUTH_ONLY` once every controller has the Resource Server plugin installed and configured. `OAUTH_ONLY` requires `OperationsCenter.OAuthServer.Enabled: true`.<br/><br/>**Default:** `AUTO` |
| `McpRouter.replicas` | Number of CloudBees CI MCP Router replicas. The CloudBees CI MCP Router keeps only in-memory caches, so one replica is enough for most fleets.<br/><br/>**Default:** `1` |
| `McpRouter.image.registry`<br/>`McpRouter.image.repository`<br/>`McpRouter.image.tag` | CloudBees CI MCP Router image coordinates. Override any of these to pull from a private registry or to pin a specific version. Set `McpRouter.image.dockerImage` to a full image path to override all coordinates at once.<br/><br/>**Default:** Chart default values |
| `McpRouter.image.pullPolicy` | Image pull policy for the CloudBees CI MCP Router container.<br/><br/>**Default:** `IfNotPresent` |
| `McpRouter.resources` | CPU, memory requests, and limits for the CloudBees CI MCP Router container. Requests and limits are set to the same value so the pod runs in the Kubernetes Guaranteed QoS class.<br/><br/>**Default:** `1` CPU / `2Gi` for both requests and limits |
| `McpRouter.ocInternalUrl` | Direct operations center service URL for calls from the CloudBees CI MCP Router to the operations center, bypassing the ingress. Use it to prevent hairpin NAT issues on GKE or EKS. Leave empty to compute it automatically from `OperationsCenter.Name` and `OperationsCenter.ContextPath` (for example, `http://cjoc/cjoc` for a standard installation). The operations center URL (`OC_URL`) remains the OAuth audience regardless of this setting.<br/><br/>**Default:** `""` |
| `McpRouter.javaOpts` | Additional Java options for the CloudBees CI MCP Router JVM. Appended to the image's built-in `JAVA_OPTS_APPEND` flags, preserving memory, garbage collection, and Quarkus defaults.<br/><br/>**Default:** not set |
| `McpRouter.imagePullSecrets` | Image pull secrets for private registry authentication. |
| `McpRouter.nodeSelector`<br/>`McpRouter.tolerations`<br/>`McpRouter.annotations`<br/>`McpRouter.podSecurityContext`<br/>`McpRouter.containerSecurityContext` | Standard Kubernetes scheduling, annotation, and security context settings for the CloudBees CI MCP Router pod and container. |

###### Private Key JWT (`McpRouter.privateKeyJwt.*`)

By default, the CloudBees CI MCP Router authenticates to the authorization server with its projected service account token. To use an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `private_key_jwt` assertion instead, configure:

* `McpRouter.privateKeyJwt.enabled`: Controls mode (`NEVER`, `ALWAYS`, `AUTO`). Default: `NEVER`.
  * `NEVER`: Uses projected service account token.
  * `ALWAYS`: Signs with the shared key. Mounts `keySecretName` if set, otherwise generates a key and keeps it.
  * `AUTO`: Signs only when `keySecretName` is set; falls back to projected service account token otherwise.
* `McpRouter.privateKeyJwt.keySecretName`: The name of a Kubernetes Secret holding the RSA signing key in PEM format. The key is shared by every CloudBees CI MCP Router replica, so all pods publish one `kid` at `/jwks`.
* `McpRouter.privateKeyJwt.keySecretKey`: The entry (file name) of the PEM within that Secret. Default: `signing-key.pem`.

When `enabled` is `ALWAYS` and no `keySecretName` is set, the chart generates a signing key and stores it in a Secret named `mcp-router-signing-key`. This works for plain Helm, but under GitOps or `--dry-run`, the chart cannot look up the existing Secret and might regenerate the key. In those environments, create and name your own Secret:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out signing-key.pem
kubectl create secret generic mcp-router-signing-key --from-file=signing-key.pem
```

###### Extra Environment Variables (`McpRouter.extraEnv`)

Extra environment variables for the CloudBees CI MCP Router container, for example to set `mcp.router.*` properties such as the controller cache TTL. Default: `[]`.

For example, to set the controller cache TTL:

```yaml
McpRouter:
  extraEnv:
    - name: MCP_ROUTER_OC_CONTROLLERS_CACHE_TTL
      value: "10M"
```

#### Manually Configure OAuth

If you do not use the Helm chart, you must configure the OAuth components manually. Configure the authorization server and resource server in CloudBees CI, and then start the CloudBees CI MCP Router with the corresponding environment variables.

##### Configure Authorization Server and Resource Server Using the UI

**1. Configure the Resource Server (Operations Center and Controllers):**

1. In the operations center and on each controller, navigate to **Manage Jenkins** → **Security** and scroll down to **CloudBees OAuth Resource Server**.
2. Set **Trusted issuer** to the issuer URL of the authorization server.
   > This value must match the **Issuer URL** of the authorization server exactly. If you use the default authorization server URL, enter `<your-oc-url>/oauth-server`. If left blank, OAuth enforcement is disabled and all requests pass through to Jenkins.
3. If the canonical address of this instance differs from its root URL, set **Accepted audience** to the canonical address. Otherwise, leave it blank to use the root URL.
4. Set **Filter mode** to one of the following:
   - **AUTO** (recommended): Accepts both OAuth bearer tokens and existing sign-ins; non-Bearer requests are handled by Jenkins directly.
   - **OAUTH_ONLY**: Accepts the same bearer tokens as **AUTO**, but challenges non-Bearer requests to protected paths with `401 + PRM`.
   - **ROUTER_ONLY**: Accepts only tokens issued through the CloudBees CI MCP Router and rejects all other requests to protected paths.
5. Select **Save** to apply the changes.

**2. Configure the Authorization Server (Operations Center only):**

1. In the operations center, navigate to **Manage Jenkins** → **Security** and scroll down to **CloudBees OAuth Authorization Server**.
2. Leave **Issuer URL** blank to use the default, `<your-oc-url>/oauth-server`, which matches the **Trusted issuer** value set on the resource server. If the authorization server is reachable at a different public address than the operations center, set **Issuer URL** to that address instead.
3. Leave **Internal JWKS URL** blank in most cases; controllers fetch the signing keys from the issuer’s public `/jwks` endpoint. Set it only if a controller cannot reach that public address, for example an internal address reachable only over HTTP.
4. For **Allowed audiences**, add the addresses of the controllers and the CloudBees CI MCP Router that are allowed to receive exchanged tokens, one per line.
5. Set **Router client secret** to a strong random secret. Record it, as you will need it when you configure the CloudBees CI MCP Router (where it is set as `ROUTER_CLIENT_SECRET`).
6. Select **Save** to apply the changes.

##### (Optional) Tune the Manual Configuration

The settings above are sufficient for most deployments. The following settings let you tune the resource server and authorization server when the defaults do not fit your environment.

**Tune resource server settings (Operations Center and controllers):**
1. In the operations center and on each controller, navigate to **Manage Jenkins** → **Security** and scroll down to **CloudBees OAuth Resource Server**.
2. Leave **JWKS URL override** blank in most cases; by default the JWKS is fetched from `{trustedIssuer}/jwks` over HTTPS. Set it only if this instance’s public hostname is unreachable from inside the cluster (hairpin NAT), to an internal address such as `http://cjoc/cjoc/oauth-server/jwks`.
3. If you selected **ROUTER_ONLY** for **Filter mode**, set **PRM resource URI** to the CloudBees CI MCP Router URL, so MCP clients discover CloudBees CI MCP Router instead of connecting to Jenkins directly.
4. If MCP endpoints on this instance are served from a path other than `/mcp-server/*`, add those paths to **Protected paths**, one per line or comma-separated.
5. If you need to tune how long JWKS keys are cached, adjust **JWKS cache TTL** (default: `300` seconds).
6. If you need to adjust the leeway for token expiry validation, adjust **Clock skew** (default: `60` seconds).

**Tune authorization server settings (Operations Center only):**
1. In the operations center, navigate to **Manage Jenkins** → **Security** and scroll down to **CloudBees OAuth Authorization Server**.
2. If you want the operations center to overwrite any locally set trusted issuer on connected controllers, select **Enforce trusted issuer on controllers**. Otherwise, the operations center seeds its issuer only on controllers that have none, leaving deliberate local values alone.
3. If your security policy requires shorter token lifetimes than the defaults, adjust **Access token TTL** (default: `600` seconds) and **Exchanged token TTL** (default: `300` seconds). Exchanged tokens should be shorter than access tokens, because they can always be re-exchanged.
4. To let untrusted clients self-register (for example, MCP Inspector or similar tooling that automatically registers), select **Enable Dynamic Client Registration**.
   > Leave this disabled on a publicly reachable authorization server to prevent unbounded client creation.
5. If you selected **Enable Dynamic Client Registration** and an MCP client fails to register because it looks for `/register` at the Jenkins root instead of at `/oauth-server/register`, enable **Also serve /register at Jenkins root**.
6. If you selected **Enable Dynamic Client Registration** and your security policy requires different DCR client lifetimes than the defaults, adjust **DCR client secret TTL** (default: `180` days), **DCR refresh-token TTL** (default: `30` days), and **Idle DCR client TTL** (default: `90` days). Note: These lifetimes are entered in seconds in the UI.
7. If you selected **Enable Dynamic Client Registration** and want to manage clients manually through the UI, disable **Evict idle DCR clients**. Otherwise, leave it enabled so the daily sweep evicts idle DCR clients.
8. To bypass the consent prompt on first use for the pre-seeded `cloudbees-mcp-router` and `ci-mcp-client` clients, enable **Auto-approve seeded clients**.
   > Enable this only if you accept that these platform clients act on a user’s identity without explicit approval.
9. If clients authenticate with `private_key_jwt` and your security policy requires different client assertion or JWKS lifetimes than the defaults, adjust **Client assertion max lifetime** (default: `300` seconds), **Client assertion clock skew** (default: `30` seconds), and **JWKS cache TTL** (default: `300` seconds).
10. If you use the RFC 7523 jwt-bearer grant to trade external JWTs (such as Kubernetes service account tokens or GitHub Actions OIDC tokens) for CloudBees CI MCP Router tokens, under **Trusted assertion issuers**, select **+ Add trusted issuer**, and configure each external issuer:
    * Set **Issuer (iss)** to the exact value of the assertion’s `iss` claim, for example, `https://token.actions.githubusercontent.com` or the Kubernetes API server issuer.
    * Set **Expected audience (aud)** to a value unique to this authorization server, so a token minted for another service cannot be replayed at this endpoint.
    * Set **Bound Jenkins user id** to the Jenkins user that every assertion from this issuer maps to. The external token never chooses its own identity; you pin it here.
    * Provide the issuer’s public keys as either **Inline JWKS** or a **JWKS URL**. Prefer **JWKS URL** when the issuer rotates keys.
    * Optionally, in **Allowed audiences**, add the audiences this issuer’s tokens may target, one per line. Leave blank to inherit the global **Allowed audiences** list.
    * Optionally, in **Allowed subjects**, add the external `sub` values to accept from this issuer, one per line. Leave blank to accept any subject the issuer vouches for.

##### Configure Using Configuration as Code (CasC)

1. In the operations center CasC bundle, add the following to your `jenkins.yaml` file:

   ```yaml
   security:
     oauthAuthorizationServer:
       issuer: "https://oc.example.com/oauth-server"
       routerClientSecret: "<your-shared-secret>"
       allowedAudiences: |
         https://controller-a.example.com
         https://mcp-router.example.com
       internalJwksUrl: "<internal-address>"
   ```

   - `issuer`: Public address of the authorization server.
   - `routerClientSecret`: Shared secret the CloudBees CI MCP Router uses to authenticate to the authorization server (must match `ROUTER_CLIENT_SECRET`).
   - `allowedAudiences`: Addresses of controllers and CloudBees CI MCP Router allowed to receive exchanged tokens (one address per line).
   - `internalJwksUrl`: Optional internal JWKS URL if controllers cannot reach the public HTTPS address.

2. In the CasC bundle for the operations center and each controller, add the following to your `jenkins.yaml` file:

   ```yaml
   security:
     oauthResourceServer:
       trustedIssuer: "https://oc.example.com/oauth-server"
       acceptedAudience: "https://controller-a.example.com"
       filterMode: "AUTO"
   ```

   - `trustedIssuer`: Trusted issuer URL of the authorization server (must match `issuer` exactly).
   - `acceptedAudience`: Canonical address of this instance (defaults to instance root URL).
   - `filterMode`: `AUTO` accepts both OAuth and existing sign-ins. `OAUTH_ONLY` challenges non-Bearer requests to protected paths with `401 + PRM`. `ROUTER_ONLY` accepts only tokens issued through the CloudBees CI MCP Router.

3. Apply the bundle to your operations center and controllers.

##### Configure the CloudBees CI MCP Router Container

Start the CloudBees CI MCP Router with the following environment variables:

```bash
docker run -p 9000:9000 \
  -e OC_URL=https://oc.example.com \
  -e OAUTH_ENABLED=true \
  -e OAUTH_ISSUER=https://oc.example.com/oauth-server \
  -e OAUTH_ROUTER_AUDIENCE=https://mcp-router.example.com \
  -e ROUTER_CLIENT_ID=cloudbees-mcp-router \
  -e ROUTER_CLIENT_SECRET=<your-shared-secret> \
  -e MCP_AUTH_UPSTREAM_MODE=AUTO \
  cloudbees/ci-mcp-router:<my-tag>
```

The following values must match the authorization server configuration:
* `OAUTH_ISSUER` must match the **Issuer URL**.
* `ROUTER_CLIENT_SECRET` must match the **Router client secret**.
* `OAUTH_ROUTER_AUDIENCE` is the public address of the CloudBees CI MCP Router, and must appear in the **Allowed audiences** list of the authorization server.

> [!CAUTION]
> The router client secret allows the CloudBees CI MCP Router to obtain tokens, so protect it as you would a password. Use a Kubernetes Secret or secret store rather than passing it on the command line.

#### Verify OAuth is Working

1. Verify that the authorization server is published (returns endpoint JSON):
   ```bash
   curl https://oc.example.com/oauth-server/oauth-authorization-server
   ```
2. Verify that signing keys are available:
   ```bash
   curl https://oc.example.com/oauth-server/jwks
   ```
3. Verify that a controller advertises OAuth:
   ```bash
   curl https://controller-a.example.com/.well-known/oauth-protected-resource
   ```
4. After connecting an MCP agent, verify that you are prompted to sign in through OAuth instead of entering an API token.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/token-authentication -->

### Authenticate with an API Token

The CloudBees CI MCP Router can authenticate to CloudBees CI with an API token generated from the operations center and encoded for HTTP basic authentication.

> [!WARNING]
> Authenticating with an API token will be deprecated in the future. For new deployments, CloudBees recommends that you use [OAuth](#enable-oauth-authentication), which authenticates each request individually rather than relying on a shared token.

#### API Token Prerequisites

Before you begin, ensure that you have [installed the CloudBees CI MCP Router](#installation-and-deployment) and have an account with sufficient permissions to generate an API token in the operations center.

#### Generate an API Token

> [!CAUTION]
> You must generate an API token from the **operations center**. If you generate an API token from a controller instead of the operations center, the token is not valid for use with the CloudBees CI MCP Router and a connection cannot be established.

To generate an API token:

1. Sign in to the operations center.
2. Select your profile in the upper-right corner, and then select **Security**.
3. Select **Add new token**.
4. Enter a name to distinguish the token, and then select **Generate**.
5. Copy the token and store it in a secure location for later use. Once you leave the page, you cannot view or copy the token again.
6. Select **Done** to add the token.
7. Select **Save** to save your changes.

#### Encode Credentials for HTTP Basic Authentication

Authenticate with the CloudBees CI MCP Router using HTTP basic authentication by encoding your username and API token together.

Open a terminal and run the following command, replacing `<username>` and `<token>` with your actual username and the API token you generated in the operations center:

**Linux or macOS:**
```bash
echo -n "<username>:<token>" | base64
```

**Windows (PowerShell):**
```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("<username>:<token>"))
```

If successful, the Base64-encoded credential is output, similar to the following:
```text
dXNlcm5hbWU6dG9rZW4=
```

Store the encoded credential in a secure location for later use.

> [!WARNING]
> Base64 encoding is not encryption. Anyone with access to the encoded string can decode it and obtain your credentials. Always protect the encoded credentials as if they are the original username and token.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/mcp-agent -->

## Connecting MCP Agents

MCP agents connect MCP-compatible tools to CloudBees CI. The router supports multiple controllers, so an agent can access and manage jobs, builds, and resources across all of them.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/claude-code -->

### Connect Claude Code

Claude Code is a command-line interface (CLI) tool that connects to the CloudBees CI MCP Router through the [MCP Server plugin](/plugins/ci/mcp-server), giving it access to CloudBees CI data.

#### Prerequisites

* The [CloudBees CI MCP Router installed](#installation-and-deployment).
* Configured authentication using [OAuth](#enable-oauth-authentication) or an [API token](#authenticate-with-an-api-token).
* Claude Code installed.

#### Connect Claude Code with OAuth (Recommended)

With OAuth, you do not need to pass credentials to the command line. You sign in once, and the CloudBees CI MCP Router handles the rest.

1. Open a terminal on the machine where Claude Code is installed.
2. Run the following command to add CloudBees CI MCP Router to Claude Code:
   ```bash
   claude mcp add ci-mcp-router <router-url> --transport http --client-id ci-mcp-client
   ```
   - Replace `<router-url>` with the MCP endpoint of your router: `http://localhost:9000/mcp` for local Docker, or `https://<cluster-domain>/mcp-router/mcp` for Helm.
   - The `--client-id ci-mcp-client` flag selects the pre-seeded public client. Without it, Claude Code attempts dynamic client registration (disabled by default, failing with 403).
3. Start Claude Code:
   ```bash
   claude
   ```
4. Run the `/mcp` command:
   ```text
   /mcp
   ```
5. Select the `ci-mcp-router` server. A browser launches with an approval prompt. After you approve, Claude Code reuses the session for later requests.

#### Connect Claude Code with an API Token

1. Run the following command, replacing `dXNlcm5hbWU6dG9rZW4=` with your actual encoded credentials:
   ```bash
   claude mcp add ci-mcp-router http://localhost:9000/mcp --transport http --header "Authorization: Basic dXNlcm5hbWU6dG9rZW4="
   ```
   > Passing the encoded credential directly in this command leaves it in your shell history. Claude Code lets you reference an environment variable in the header value instead of the literal credential. For more information, refer to [Environment variable expansion in `.mcp.json`](https://code.claude.com/docs/en/mcp#environment-variable-expansion-in-mcp-json).
2. Start Claude Code:
   ```bash
   claude
   ```

#### Use Claude Code for Development Tasks

Once connected, you can ask questions and issue tasks using natural language. For a list of supported tools, refer to the [Tool Reference](#tool-reference).

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/github-copilot -->

### Connect GitHub Copilot

#### Prerequisites

* The [CloudBees CI MCP Router installed](#installation-and-deployment).
* Configured authentication using [OAuth](#enable-oauth-authentication) or an [API token](#authenticate-with-an-api-token).
* GitHub Copilot installed.

#### Connect GitHub Copilot with OAuth (Recommended)

1. Run the following command:
   ```bash
   copilot mcp add --transport http ci-mcp-router <router-url>
   ```
   *(Replace `<router-url>` with `http://localhost:9000/mcp` for Docker, or `https://<cluster-domain>/mcp-router/mcp` for Helm).*
2. Start GitHub Copilot:
   ```bash
   copilot
   ```
   A browser launches with an approval prompt. After you approve, GitHub Copilot reuses the session for later requests.

#### Connect GitHub Copilot with an API Token

1. Run the following command:
   ```bash
   copilot mcp add ci-mcp-router --transport http http://localhost:9000/mcp --header "Authorization: Basic dXNlcm5hbWU6dG9rZW4="
   ```
   > GitHub Copilot has no confirmed way to reference an environment variable in this field. Treat this configuration file as sensitive, keep it out of version control, and rotate the credential if it’s ever exposed.
2. Start GitHub Copilot:
   ```bash
   copilot
   ```

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/goose -->

### Connect Goose

#### Prerequisites

* The [CloudBees CI MCP Router installed](#installation-and-deployment).
* Configured authentication using [OAuth](#enable-oauth-authentication) or an [API token](#authenticate-with-an-api-token).
* Goose installed.

#### Connect Goose with OAuth (Recommended)

1. Run `goose configure` to start the interactive configuration:

   ```text
   ┌   goose-configure
   │
   ◇  What would you like to configure?
   │  Add Extension
   │
   ◇  What type of extension would you like to add?
   │  Remote Extension (Streamable HTTP)
   │
   ◇  What would you like to call this extension?
   │  CloudBees CI MCP Router
   │
   ◇  What is the Streaming HTTP endpoint URI?
   │  <router-url>
   │
   ◇  Please set the timeout for this tool (in secs):
   │  300
   │
   ◇  Enter a description for this extension:
   │  CloudBees CI MCP Router for Jenkins
   │
   ◇  Would you like to add custom headers?
   │  No
   │
   └  Added CloudBees CI MCP Router extension
   ```

2. Start Goose:
   ```bash
   goose session
   ```
   A browser launches with an approval prompt. After approval, Goose reuses the session.

#### Connect Goose with an API Token

1. Run `goose configure`:

   ```text
   ┌   goose-configure
   │
   ◇  What would you like to configure?
   │  Add Extension
   │
   ◇  What type of extension would you like to add?
   │  Remote Extension (Streamable HTTP)
   │
   ◇  What would you like to call this extension?
   │  CloudBees CI MCP Router
   │
   ◇  What is the Streaming HTTP endpoint URI?
   │  http://localhost:9000/mcp
   │
   ◇  Please set the timeout for this tool (in secs):
   │  300
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
   │  Basic dXNlcm5hbWU6dG9rZW4=
   │
   ◇  Add another header?
   │  No
   │
   └  Added CloudBees CI MCP Router extension
   ```

2. Start Goose:
   ```bash
   goose session
   ```

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/kiro -->

### Connect Kiro

#### Prerequisites

* The [CloudBees CI MCP Router installed](#installation-and-deployment).
* Configured authentication using [OAuth](#enable-oauth-authentication) or an [API token](#authenticate-with-an-api-token).
* Kiro installed.

#### Connect Kiro with OAuth (Recommended)

1. Add the router to Kiro:
   ```bash
   kiro-cli mcp add --name ci-mcp-router --url <router-url>
   ```
2. Start Kiro:
   ```bash
   kiro-cli
   ```
3. Press `Ctrl+y` to authenticate. Kiro copies an OAuth approval URL to your clipboard.
4. Paste the URL into your browser and approve access.

#### Connect Kiro with an API Token

1. Add the router to Kiro:
   ```bash
   kiro-cli mcp add --name ci-mcp-router --url <router-url>
   ```
2. Open the `mcp.json` configuration file created by the command and add the `headers` field:

   ```json
   {
     "mcpServers": {
       "ci-mcp-router": {
         "url": "<router-url>",
         "headers": {
           "Authorization": "Basic dXNlcm5hbWU6dG9rZW4="
         }
       }
     }
   }
   ```
3. Save `mcp.json` and start Kiro:
   ```bash
   kiro-cli
   ```

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/mcp-tool-reference -->

## Tool Reference

Tools available through the CloudBees CI MCP Router fall into two categories: a small set of tools specific to the CloudBees CI MCP Router itself, and a larger set forwarded dynamically from the [MCP Server plugin](/plugins/ci/mcp-server) running on each controller you can access.

Your MCP agent lists CloudBees CI MCP Router-specific tools and tools forwarded from the [MCP Server plugin](/plugins/ci/mcp-server) together, with no distinction between them. For the tools forwarded from the MCP Server plugin, refer to [MCP Server plugin - Available Tools](https://plugins.jenkins.io/mcp-server/#plugin-content-available-tools).

### How Tools Work

When you ask your MCP agent a question, it determines which tools to call and with what parameters. You do not need to know the exact tool names. Ask in natural language:

- **"List the controllers I can access"** → MCP agent calls `listControllers`.
- **"How many jobs are there?"** → MCP agent calls `getJobs`.
- **"Who am I?"** → MCP agent calls `whoAmI`, which reports the identity the CloudBees CI MCP Router is using for each controller it reaches (useful for troubleshooting the OAuth or token authentication chain).

### Router-Specific Tools

These tools are unique to the CloudBees CI MCP Router and are not part of the [MCP Server plugin](/plugins/ci/mcp-server).

#### `listControllers`

Lists the controllers this operations center manages, so you can map a deployment’s topology and check controller availability before calling other tools.

- **Returns:** Controller name, full path, display name, description, page in operations center UI (`url`), controller base URL (`endpoint`), last known Jenkins version, lifecycle state, and status (`online`, `offline`, or `hibernated`).
- **Parameters:** Accepts an optional `names` array to filter by exact short name or full path (for example, `ctrl-a` or `team-a/ctrl-a`). A folder name alone matches nothing, and omitting the array returns every accessible controller.

### Tool Access and Permissions

Access to CloudBees CI MCP Router tools depends on which controllers your credentials grant access to. When a call targets multiple controllers, each controller succeeds or fails independently, so a controller you do not have permission to access returns its own access-denied result without affecting the other controllers.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/troubleshooting -->

## Troubleshooting

If you encounter problems configuring or connecting CloudBees CI MCP Router, use this guidance to identify the cause and resolve the issue.

### Common Misconfigurations

If OAuth requests are rejected after configuration, check the following common misconfigurations:

* **Issuer mismatch:** The **Trusted issuer** on the resource server and the `OAUTH_ISSUER` of the CloudBees CI MCP Router must both match the **Issuer URL** of the authorization server exactly, including `https://` and any trailing path.
* **Audience mismatch:** Each controller and the CloudBees CI MCP Router must appear in the **Allowed audiences** list of the authorization server, and the **Accepted audience** of each instance must be its own address.
* **Keys unreachable:** Controllers fetch the signing keys from the issuer’s public HTTPS `/jwks` endpoint by default. If a controller genuinely cannot reach that address, set the **Internal JWKS URL** on the authorization server to an internally reachable **HTTPS** address.

If the issue persists, contact [CloudBees Support](https://support.cloudbees.com).

### Compromised Signing Key Reference

If you suspect the authorization server’s OAuth signing key material has been exposed, refer to [Incident Response: Force-Remove a Compromised OAuth Signing Key](#incident-response-force-remove-a-compromised-oauth-signing-key) to force-remove the compromised key from the JSON Web Key Set (JWKS) immediately, rather than waiting for scheduled rotation.

### Debug Logging (UI)

If OAuth requests are failing, enable `FINE`-level logging for the [CloudBees OAuth Resource Server plugin](/plugins/ci/cloudbees-oauth-resource) on the operations center or controller that is rejecting the request. This produces detailed bearer token validation traces, including `bearer_reject` lines when a request is passed through without a valid bearer token.

To enable debug logging in the UI:

1. In the operations center or controller, navigate to **Manage Jenkins** → **System Log**.
2. Select **+ Add recorder**.
3. On the **New log recorder** screen, enter a name (for example, `oauth-resource`) and select **Create**.
4. Under **Loggers**, select **+Add**:
   - **Logger:** `com.cloudbees.jenkins.plugins.oauth.resource`
   - **Log level:** `FINE`
5. Select **Save**.

Logs are displayed in real time on the recorder page and written to the Jenkins log.

> [!TIP]
> `FINE` logging is verbose. Disable it once you have identified the issue.

### Debug Logging (Configuration as Code)

To enable debug logging using Configuration as Code (CasC):

1. In the CasC bundle for the operations center or controller, add the following to your `jenkins.yaml` file:

   ```yaml
   unclassified:
     log:
      recorders:
        - name: oauth-resource
          loggers:
            - name: com.cloudbees.jenkins.plugins.oauth.resource
              level: FINE
   ```

2. Apply the bundle to your operations center and controllers.

---

<!-- Source: https://docs.cloudbees.com/docs/cloudbees-ci/latest/mcp-router/signing-key-incident -->

## Incident Response: Force-Remove a Compromised OAuth Signing Key

If an OAuth signing key on the operations center’s authorization server may be compromised, follow these steps to remove it immediately, without waiting for scheduled key rotation to complete. For example, `$JENKINS_HOME/secrets/master.key` on the operations center may have leaked through a host compromise, a backup leak, or a container escape, because that key decrypts the signing key at rest.

> [!NOTE]
> `master.key` is a product-wide CloudBees CI root secret. Protecting it through host hardening, backup handling, and container isolation is outside the scope of this procedure and of the CloudBees CI MCP Router. This procedure covers only the OAuth signing key.

### Signing Key Rotation

The authorization server holds at most two signing keys:
* **Active key:** Signs new tokens.
* **Retiring key:** Stays published during a short overlap window so that tokens issued before a rotation still validate.

The key material is stored, encrypted, in `$JENKINS_HOME/cloudbees-oauth-server/signing-keys.xml` on the operations center.

Two behaviors make incident response necessary:
* The operations center publishes public keys from the JSON Web Key Set (JWKS) endpoint (`/oauth-server/jwks`), and controllers cache the key set with a lifetime of up to 300 seconds (five minutes).
* Scheduled rotation only drops the retiring key after the overlap window elapses. It does not evict a key on demand.

> [!IMPORTANT]
> A single rotation does not remove a compromised key. Rotating once demotes the current active key to the retiring slot, where it stays published in the JWKS and continues to validate forged tokens. You must rotate **twice** to evict it; the second rotation overwrites the retiring slot with a freshly generated key.

### Remove the Compromised Key

The following steps rotate the signing key twice, which evicts the compromised key from the JWKS regardless of whether it was the active or retiring key.

You need **Overall/Administer** permission on the operations center to complete this procedure.

1. Fetch the JWKS from the authorization server and note the `kid` values currently published:
   ```bash
   curl -s https://oc.example.com/oauth-server/jwks | jq '.keys[].kid'
   ```
   The active `kid` is also written to the operations center log on every rotation (`Signing key rotated. Active kid=…`). Confirm which `kid` corresponds to the compromised key before continuing.

2. On the operations center, navigate to **Manage Jenkins** → **Script Console** and run the following script:

   ```groovy
   import com.cloudbees.jenkins.plugins.oauth.server.SigningKeys

   def keys = SigningKeys.get()
   println "before: " + keys.allPublicJwks()*.getId()

   // First rotation: the compromised active key becomes the retiring key (still published),
   // and a fresh active key is generated.
   keys.rotate()
   // Second rotation: overwrites the retiring slot, evicting the compromised key entirely.
   keys.rotate()

   println "after:  " + keys.allPublicJwks()*.getId()
   ```

   The compromised `kid` must not appear in the `after:` list. Both listed keys should be freshly generated.

   *(If the operations center Script Console is unavailable, stop the operations center, delete `$JENKINS_HOME/cloudbees-oauth-server/signing-keys.xml`, and restart. A new active key is generated on startup. This invalidates all previously issued tokens, not only forged ones).*

3. Fetch the JWKS again and confirm the compromised `kid` no longer appears:
   ```bash
   curl -s https://oc.example.com/oauth-server/jwks | jq '.keys[].kid'
   ```

   New tokens are already signed with the fresh active key. Any token still bearing the compromised `kid` now fails validation at the authorization server with an `unknown kid` error.

### Key Rotation Propagation

The authorization server stops advertising the compromised key immediately. Each controller caches the JWKS for up to 300 seconds (five minutes), so the change propagates across the fleet within one cache lifetime. A controller that receives a token with an unrecognized `kid` refreshes its cached key set sooner (subject to a short refetch cooldown), so in practice most controllers pick up the new key set within seconds of the next request.

### Post-Incident Follow-Up

After removing the key, take the following steps to investigate and prevent future exposure:
* Investigate what exposed the key material. If `master.key` may have leaked, treat it as a CloudBees CI-wide incident.
* Revoke affected users' grants and refresh tokens if their credentials may also be compromised.

For other OAuth issues, refer to [Troubleshooting](#troubleshooting).
