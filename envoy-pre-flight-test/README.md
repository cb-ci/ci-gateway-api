# Envoy Gateway Pre-Flight Test (GKE)

Verifies that Envoy Gateway and the Kubernetes Gateway API work on a GKE cluster before installing CloudBees CI behind it. `install.sh` deploys a test workload and exposes it through an HTTPS Gateway. `uninstall.sh` cleans up.

## What `install.sh` does

1. Loads `./.env` and validates `CLUSTER_NAME`, `ZONE` and `CERT_NAME`.
2. Checks that `helm`, `kubectl` and `gcloud` are installed, and that the GKE cluster is reachable.
3. Installs Envoy Gateway (release `eg`, namespace `envoy-gateway-system`) from a locally pulled chart in `./gateway-helm`. The bundled Gateway API CRDs are removed because GKE manages them. Skipped if the release already exists.
4. Creates namespace `test-ns` and sets it as the current kubectl context namespace.
5. Generates a self-signed certificate (`../scripts/generate-ssl-cert.sh`, output in `../ssl/`) and creates the TLS secret `CERT_NAME`.
6. Deletes existing `Gateway` and `HTTPRoute` resources in `test-ns`, then applies:
   - PVC (`premium-rwo`), an nginx Pod and a ClusterIP Service
   - `GatewayClass` `eg`, `Gateway` `test-gateway-1` (HTTPS/443, TLS terminate) and `HTTPRoute` `test-route` (`/test`)
   - `BackendTrafficPolicy` `test-traffic-policy` (active HTTP health check)
7. Waits 120 s, reads the Gateway address and runs `curl -Lvk https://<address>/test`.

## Prerequisites

- `helm`, `kubectl`, `gcloud`, `openssl`, `curl`
- `gcloud` authenticated, with kubeconfig pointing at the target cluster (`gcloud container clusters get-credentials`)
- Permissions to create namespaces, PVCs, Gateway API resources and a LoadBalancer in the cluster
- Access to `docker.io` (OCI chart pull)

## Configuration

```bash
cp .env.template .env
# edit .env
```

`.env` is loaded from this directory and is git-ignored (`**/.env`).

| Variable | Required | Default | Description |
|---|---|---|---|
| `CLUSTER_NAME` | yes | – | GKE cluster name |
| `ZONE` | yes | – | Cluster zone (used with `gcloud container clusters describe --zone`) |
| `CERT_NAME` | yes | – | Name of the TLS secret used by the Gateway listener |
| `ENVOY_GATEWAY_VERSION` | no | `latest` | Envoy Gateway Helm chart version (`install.sh` only). Pin an explicit version if `latest` does not resolve. |
| `ENVOY_GW_NAMESPACE` | no | `envoy-gateway-system` | Namespace of the Envoy Gateway release (both scripts) |
| `NAMESPACE` | no | `test-ns` | Namespace for the test workload and Gateway (both scripts) |
| `TEST_HOST_NAME` | no | `example.com` | Host name for the generated certificate (`install.sh`) |
| `GATEWAY_CLASS_NAME` | no | `eg` | GatewayClass name (both scripts) |

Both scripts load `.env`; `uninstall.sh` fails if the file is missing. Use the same values for both, otherwise `uninstall.sh` targets different resources than `install.sh` created.

Hardcoded in `install.sh` (edit the script to change): Gateway `test-gateway-1`, route `test-route`, policy `test-traffic-policy`, StorageClass `premium-rwo`.

## Usage

```bash
./install.sh
./uninstall.sh
```

Run this against a test cluster first. Both scripts change shared cluster state.

## What `uninstall.sh` does

- Removes finalizers from Gateways, HTTPRoutes and the GatewayClass.
- Uninstalls the Helm release `cloudbees-core-envoy` in `test-ns`, if present.
- Keeps the Envoy Gateway Helm release `eg`, for reuse across runs.
- Deletes GatewayClass `eg`, then namespaces `test-ns` and `envoy-gateway-system`. The last one removes the Envoy Gateway controller, even though the release is reported as "preserved".
- Reads `.env` for the shared namespace and GatewayClass variables.
- Prints a command to delete the Gateway API / Envoy CRDs. It does not run it.

## Notes

- The certificate is self-signed (`curl -k`). Use it for testing only.
- The 120 s wait is fixed. LoadBalancer provisioning can take longer, so the curl step may need a re-run.
- Generated files in `../ssl/` (`server.key`, `jenkins.pem`) are git-ignored.
