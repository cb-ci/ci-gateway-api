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
- [**`gke/.env`**](../.env) file configured (copy from `gke/.env-template`).

## Getting Started

### 1. Installation

Run the installation script to deploy Envoy Gateway and CloudBees CI. It generates a self-signed SSL certificate for `CJOC_HOST_NAME` automatically as part of the run — you don't need to generate one manually first.

```bash
chmod +x 01-install-envoy.sh
./01-install-envoy.sh
```

If you want to pre-generate or inspect the certificate yourself, you can still run:

```bash
# From this directory
../../scripts/generate-ssl-cert.sh "$CJOC_HOST_NAME"
```

### 2. Verification

Retrieve the initial admin password and visit the URL provided at the end of the installation script:

```bash
kubectl exec -ti cjoc-0 -n cloudbees-envoy -- cat /var/jenkins_home/secrets/initialAdminPassword
```

Visit: `https://${CJOC_HOST_NAME}/cjoc`

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

# Troubleshooting

## No External IP assigned

On GKE, the LoadBalancer service is provisioned automatically. If it's pending:

- Check the service status: `kubectl get svc -n envoy-gateway-system`
- Describe the Gateway: `kubectl describe gateway -n cloudbees-envoy`

## 503 / No Healthy Upstream

Active health checks are enforced by Envoy. If backends are not yet ready, Envoy will not route traffic until `healthyThreshold` is met. Check pod readiness:

```bash
kubectl get pods -n cloudbees-envoy
kubectl describe backendtrafficpolicy -n cloudbees-envoy
```

## Test with curl

```bash
curl -v -L -k https://${CJOC_HOST_NAME}/cjoc/health?probe=liveness
curl -v -L -k https://${CJOC_HOST_NAME}/cjoc/health?probe=readiness
curl -v -L -k https://${CJOC_HOST_NAME}/cjoc/health?probe=startup
```

- Requires controller "$CONTROLLER" to be created first

```bash
curl -v -L -k https://${CJOC_HOST_NAME}/${CONTROLLER}/health?probe=liveness
curl -v -L -k https://${CJOC_HOST_NAME}/${CONTROLLER}/health?probe=readiness
curl -v -L -k https://${CJOC_HOST_NAME}/${CONTROLLER}/health?probe=startup
```

- Sticky session test

Note: This only works if stickysessions is enabled in envoy gateway. Its not enabled in this setup (not GA yet), so envoy beta is required

```bash
curl -c cookie.txt -v -L -k https://${CJOC_HOST_NAME}/${CONTROLLER}/health?probe=readiness
curl -b cookie.txt -v -L -k https://${CJOC_HOST_NAME}/${CONTROLLER}/health?probe=readiness
```

## Get Bundle Link Secret/URL

```
kubectl get secret controller2-corecasc-bundle-link -n cloudbees-envoy \
  -o jsonpath='{.data.bundle-link\.yaml}' | base64 -d; echo
```

- Sample output

```
url: "<http://casc-bundle-service.cloudbees-envoy.svc.cluster.local/casc-bundle-service/api/v1/bundles/download/zip-bundle>"
```

```
kubectl get secret casc-bundle-service-config -n cloudbees-envoy \
  -o jsonpath='{.data.service-configuration\.yaml}' | base64 -d; echo
```

- Sample output

```
connectors:
- id: githup-app-connector
  url: https://github.com/cb-ci/ci-gateway-api.git
  webhookSecret: "mysecret"
  branch: main
  path: casc/controller-base
  credential:
    credentialId: github-app-cred
    type: reference
credentials:
  - credentialId: github-app-cred
    type: githubAppKey
    appId: ....
    privateKey: |
      -----BEGIN PRIVATE KEY-----
      ......  
      -----END PRIVATE KEY-----
```

## CasC Bundle Service Endpoints

- Get all bundle references:

```
kubectl exec -c jenkins cjoc-0 -- sh -c 'curl -sH "Authorization: Bearer `cat /var/run/secrets/tokens/casc-bundle-service`" http://casc-bundle-service/casc-bundle-service/api/v1/bundles/all' | jq

kubectl exec -c jenkins cjoc-0 -- sh -c 'curl -sH "Authorization: Bearer `cat /var/run/secrets/tokens/casc-bundle-service`" http://casc-bundle-service/casc-bundle-service/api/v1/bundles/all' \
  | jq -r '.[].bundleReference' | base64 -d; echo

kubectl exec -c jenkins cjoc-0 -- sh -c 'curl -sH "Authorization: Bearer `cat /var/run/secrets/tokens/casc-bundle-service`" http://casc-bundle-service/casc-bundle-service/api/v1/bundles/all' \
  | jq 'map(. + {decodedReference: (.bundleReference | @base64d)})'  

```

- Sample output

```
githup-app-connector:controller
```

**Get metrics:**

```
kubectl exec -c jenkins cjoc-0 -- sh -c 'curl -sH "Authorization: Bearer `cat /var/run/secrets/tokens/casc-bundle-service`" http://casc-bundle-service/casc-bundle-service/api/v1/metrics' | jq 
```

- Sample output

```
{
  "connectorsCount": 1,
  "controllersCount": 1,
  "scmGithubCount": 1,
  "scmBitBucketCount": 0,
  "scmGitlabCount": 0,
  "scmOtherCount": 0,
  "protocolSshCount": 0,
  "protocolHttpCount": 1,
  "credentialUsernamePasswordCount": 0,
  "credentialTokenCount": 0,
  "credentialSshCount": 0,
  "credentialGithubAppCount": 1
}
```

**download bundle***

```
kubectl exec -c jenkins controller2-0 -- sh -c 'curl -sH "Authorization: Bearer `cat /var/run/secrets/tokens/casc-bundle-service`" http://casc-bundle-service/casc-bundle-service/api/v1/bundles/download/zip-bundle' > test.zip 

```

**Bundle endpoints — `BundlesEndpoint.java`, base path `api/v1`**

| Method | Path | Auth | Parameters |
| -------- | ------ | ------ | ------------ |
| GET | `/api/v1/bundles/download/zip-bundle` | Required | Query (optional): `version` — if present (any value), returns bundle version as `text/plain` instead of the zip. Implicit: caller's Service Account (from bearer token) resolves which bundle to return via `bundleReferenceManagement.getBundleReference(principal.getName())` — no explicit bundle ID param; it's tied to who's calling. Response: zip binary (`application/octet-stream`) with `Content-Disposition: attachment`. |
| GET | `/api/v1/bundles/all` | Required | None. Returns JSON array of `BundleYamlDTO` for all bundles (including duplicates), sorted by description. |
| GET | `/api/v1/bundles/duplicates` | Required | None. Returns JSON array of `BundleYamlDTO` for bundles with duplicate IDs (omits the first occurrence of each). |
| GET | `/api/v1/bundles` | Required | None. Returns JSON array of `BundleYamlDTO`, de-duplicated by bundle ID (first occurrence kept). |

#### Metrics — `MetricsEndpoint.java`

| Method | Path | Auth | Parameters |
|--------|------|------|------------|
| GET | `/api/v1/metrics` | Required | None. Returns `MetricsDTO` as JSON. |

#### Webhook endpoints (no `@Authenticated` — instead use per-provider signature/secret validation)

| Method | Path | Content-Type | Required headers | Body |
| -------- | ------ | -------------- | ------------------ | ------ |
| POST | `/api/v1/github-webhook` | `application/x-www-form-urlencoded` | `X-GitHub-Event` (push or pull_request), `X-Hub-Signature-256` (HMAC signature) | Form param `payload` (JSON string) — 400/error if empty |
| POST | `/api/v1/github-webhook` | `application/json` | Same as above | Raw JSON GitHub event payload |
| POST | `/api/v1/gitlab-webhook` | `application/json` | `X-Gitlab-Event` (must be Push Hook), `X-Gitlab-Token` (shared secret) | JSON body deserialized to GitlabEvent |
| POST | `/api/v1/bitbucket-webhook` | `application/json` | `X-Event-Key` (must be repo:push), `X-Hub-Signature-256` (HMAC signature) | Raw JSON payload deserialized to BitbucketEvent |

**Notes:**

- Only `push` and `pull_request` (actions `opened`/`synchronize`) event types are processed for GitHub; anything else returns 200 OK with "Event was not processed" and is a no-op.
- All three return a `RetrieverResponse` — `ok(message)` or `fail(exception)` — and process the actual retrieval asynchronously (fire-and-forget to an executor), so the HTTP response doesn't reflect validation outcome (as discussed earlier).

#### Health probes (MicroProfile Health — Quarkus default paths, no custom `@Path`)

| Method | Path | Auth | Parameters |
|--------|------|------|------------|
| GET | `/q/health/live` | None | None — always returns UP. |
| GET | `/q/health/ready` | None | None — UP once AppLifecycleBean startup has completed, else DOWN. |

---

## Calculate Bundle version sha1

```bash
cat <<'EOF' > /tmp/test.sh
#!/bin/bash

set -e

folder="${1:?usage: $0 <bundle-folder>}"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Same ordering as Files.walk(folder).sorted(), .git excluded
find "$folder" -type f -not -path '*/.git/*' | sort | while IFS= read -r f; do
    if [[ "$(basename "$f")" == "bundle.yaml" ]]; then
        # remove the version: key before hashing (mirrors removeVersionAttribute)
        grep -v '^version:[[:space:]]*' "$f" >> "$tmp"
    else
        cat "$f" >> "$tmp"
    fi
done
sha1sum "$tmp" | awk '{print $1}'
EOF

chmod +x /tmp/test.sh

```

---

## Reference Documentation

| Topic | Documentation Link |
| :--- | :--- |
| **Envoy Gateway Overview** | [envoyproxy.io/docs/gateway](https://gateway.envoyproxy.io/docs/) |
| **BackendTrafficPolicy** | [Envoy Gateway — BackendTrafficPolicy](https://gateway.envoyproxy.io/docs/api/extension_types/#backendtrafficpolicy) |
| **Consistent Hash Load Balancing** | [Envoy LB Policy Docs](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers) |
| **Kubernetes Gateway API** | [Official SIG Docs](https://gateway-api.sigs.k8s.io/) |
| **Envoy Gateway Helm Chart** | [charts.envoyproxy.io](https://charts.envoyproxy.io) |
