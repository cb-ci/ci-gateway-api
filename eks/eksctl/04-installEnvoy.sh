#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04-installEnvoy.sh — Install Envoy Gateway, the Gateway API resources and the
# public ALB on EKS. Teardown: 04-deleteEnvoy.sh
# -----------------------------------------------------------------------------
set -eo pipefail

set -euo pipefail

# Load environment variables
source ./.env

# Helper logging functions
log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }


# --- Install Envoy Gateway ---
# Teardown lives in 04-deleteEnvoy.sh. This script is idempotent on its own:
# every step below is an `apply` or `helm upgrade --install`, so re-running it
# converges without needing to destroy first.
log "Ensuring namespace ${ENVOY_GW_NAMESPACE} exists..."
kubectl create namespace "${ENVOY_GW_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Applying Envoy Gateway CRDs..."
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
${HELM_VERSION_FLAG} \
--set crds.gatewayAPI.enabled=true \
--set crds.gatewayAPI.channel=standard \
--set crds.envoyGateway.enabled=true \
| kubectl apply -n ${ENVOY_GW_NAMESPACE} --server-side --force-conflicts -f -

log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
${HELM_VERSION_FLAG} \
--namespace "${ENVOY_GW_NAMESPACE}" \
--create-namespace \
--skip-crds

log "Waiting for Envoy Gateway controller to be ready..."
kubectl rollout status deployment/envoy-gateway -n "${ENVOY_GW_NAMESPACE}" --timeout=120s

# --- Create Kubernetes Namespace for CJOC---
log "Configuring namespace ${NAMESPACE_CLOUDBEES}..."
kubectl create namespace "${NAMESPACE_CLOUDBEES}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace ${NAMESPACE_CLOUDBEES} cloudbees.com/gateway-routes=enabled --overwrite

# --- AWS ACM Certificate Management ---
# The certificate is attached to the ALB (see the Ingress at the end of this
# script), not to the Envoy Service. TLS terminates at the ALB; Envoy speaks
# plain HTTP behind it.
AWS_REGION=${AWS_DEFAULT_REGION:-us-east-1}
if [[ -z "${ACM_CERT_ARN:-}" ]]; then
  # Filter on ISSUED. Without this, a stale PENDING_VALIDATION or FAILED cert
  # from an earlier run gets silently reused and the listener comes up bare.
  log "Checking for an ISSUED ACM certificate for '${CJOC_HOST_NAME}' in '${AWS_REGION}'..."
  ACM_CERT_ARN=$(aws acm list-certificates --region "${AWS_REGION}" \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${CJOC_HOST_NAME}'].CertificateArn | [0]" --output text 2>/dev/null || true)

  if [[ -z "${ACM_CERT_ARN}" || "${ACM_CERT_ARN}" == "None" ]]; then
    log "No issued certificate found. Requesting an Amazon-issued ACM certificate..."
    ACM_CERT_ARN=$(aws acm request-certificate --region "${AWS_REGION}" \
      --domain-name "${CJOC_HOST_NAME}" \
      --validation-method DNS \
      --tags Key=Name,Value="${CJOC_HOST_NAME}-acm-cert" Key=cb-user,Value="${TAG_CB_USER:-acaternberg}" Key=cb-owner,Value="${TAG_CB_OWNER:-professional-services}" Key=cb-environment,Value="${TAG_CB_ENVIRONMENT:-demo}" \
      --query "CertificateArn" --output text)
    success "Requested certificate: ${ACM_CERT_ARN}"

    # --- DNS validation (previously a manual TODO — now automated) ---
    # ACM populates ResourceRecord asynchronously; poll until it appears.
    log "Waiting for ACM to publish the DNS validation record..."
    VALIDATION_NAME=""; VALIDATION_VALUE=""
    for _ in $(seq 1 30); do
      read -r VALIDATION_NAME VALIDATION_VALUE < <(aws acm describe-certificate \
        --region "${AWS_REGION}" --certificate-arn "${ACM_CERT_ARN}" \
        --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
        --output text 2>/dev/null || echo "")
      [[ -n "${VALIDATION_NAME}" && "${VALIDATION_NAME}" != "None" ]] && break
      sleep 5
    done
    [[ -n "${VALIDATION_NAME}" && "${VALIDATION_NAME}" != "None" ]] \
      || error "ACM never returned a validation record for ${ACM_CERT_ARN}"

    ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "${CJOC_HOST_NAME}")}"
    log "Resolving hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
    HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
      --dns-name "${ROUTE53_ZONE_DOMAIN}." \
      --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
      --output text | sed 's#/hostedzone/##')
    [[ -n "${HOSTED_ZONE_ID}" && "${HOSTED_ZONE_ID}" != "None" ]] \
      || error "no public hosted zone for '${ROUTE53_ZONE_DOMAIN}' — create it, or set ROUTE53_ZONE_DOMAIN in .env"

    log "Upserting validation CNAME ${VALIDATION_NAME} into zone ${HOSTED_ZONE_ID}..."
    aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" \
      --change-batch "{
        \"Changes\": [{
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"${VALIDATION_NAME}\",
            \"Type\": \"CNAME\",
            \"TTL\": 60,
            \"ResourceRecords\": [{\"Value\": \"${VALIDATION_VALUE}\"}]
          }
        }]
      }" >/dev/null

    log "Waiting for ACM to validate and issue (typically 2-5 min)..."
    sleep 300
    aws acm wait certificate-validated --region "${AWS_REGION}" --certificate-arn "${ACM_CERT_ARN}" \
      || error "certificate ${ACM_CERT_ARN} was not issued — check DNS propagation and ACM console"
    success "Certificate issued: ${ACM_CERT_ARN}"
  else
    success "Found issued certificate: ${ACM_CERT_ARN}"
  fi
fi

# --- Envoy Gateway Resources ---
# Topology: Internet -> ALB (TLS, ACM cert) -> Envoy Service (ClusterIP, plain
# HTTP) -> Gateway -> HTTPRoute -> CJOC. The ALB is created from the Ingress at
# the bottom of this script, NOT from the Envoy Service.
log "Applying EnvoyProxy (Envoy Service shape)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: eg-aws-lb
  namespace: ${ENVOY_GW_NAMESPACE}
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        # ClusterIP, not LoadBalancer: the ALB reaches Envoy pods directly via
        # target-type ip, so no cloud load balancer is needed on the Service.
        type: ClusterIP
EOF

# The EnvoyProxy is attached via GatewayClass.spec.parametersRef. This is the
# only supported mechanism (along with Gateway.spec.infrastructure.parametersRef).
# The previous gateway.envoyproxy.io/infra-backend* annotations were not a real
# API, so the EnvoyProxy was orphaned and Envoy fell back to a default
# LoadBalancer Service -- which EKS turned into an unconfigured Classic ELB.
log "Applying GatewayClass (with parametersRef -> EnvoyProxy)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: eg-aws-lb
    namespace: ${ENVOY_GW_NAMESPACE}
EOF

log "Applying Gateway..."
# Plain apply — Gateway listeners are mutable, so the delete-then-recreate this
# used to do was unnecessary and cost an ALB target-group churn on every run.
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE_CLOUDBEES}
spec:
  gatewayClassName: eg
  listeners:
  # Listener NAME must stay "https" -- 05-inatallCloudBees.sh passes
  # Gateway.SectionName=https and the chart binds its HTTPRoute to that name.
  # Protocol is HTTP because the ALB in front has already terminated TLS.
  - name: https
    protocol: HTTP
    port: 443
    allowedRoutes:
      namespaces:
        from: All
EOF

# Fix reverse proxy broken 
# See more info at : https://gateway.envoyproxy.io/latest/api/extension_types/#pathsettings
# and https://gateway.envoyproxy.io/latest/api/extension_types/#pathescapedslashaction
#Jenkins’ reverse proxy monitor requests an encoded callback URL:
#  /cjoc/administrativeMonitor/hudson.diagnosis.ReverseProxySetupMonitor/testForReverseProxySetup/...
# This URL contains encoded slashes like %2F. When Envoy sees these encoded slashes, it attempts to "UnescapeAndRedirect", but fails with path_normalization_failed (in Envoy access logs). The solution is to change this default behaviour from  "UnescapeAndRedirect" to "KeepUnchanged". This is done with creating a new policy and attaching to the gateway:
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: keep-escaped-slashes
  namespace: ${NAMESPACE_CLOUDBEES}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY_NAME}
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1
  path:
    escapedSlashesAction: KeepUnchanged
EOF

# --- ALB (Ingress in front of the Envoy Service) ---
# Envoy Gateway names the Service it generates
# "envoy-<gw-namespace>-<gw-name>-<hash>", so the name cannot be hardcoded.
# Discover it by the owning-gateway labels instead.
log "Waiting for Envoy Gateway to generate its Service..."
ENVOY_SVC=""
for _ in $(seq 1 30); do
  ENVOY_SVC=$(kubectl get svc -n "${ENVOY_GW_NAMESPACE}" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${NAMESPACE_CLOUDBEES}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${ENVOY_SVC}" ]] && break
  sleep 5
done
[[ -n "${ENVOY_SVC}" ]] || error "Envoy Service never appeared in ${ENVOY_GW_NAMESPACE} — check 'kubectl get gateway -n ${NAMESPACE_CLOUDBEES}'"
success "Envoy Service: ${ENVOY_SVC}"

log "Applying Ingress (provisions the public ALB)..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cjoc-alb
  # Must live alongside the Envoy Service it targets, not with the Gateway.
  namespace: ${ENVOY_GW_NAMESPACE}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "${ACM_CERT_ARN}"
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    # ALB defaults to a 60s idle timeout, which severs Jenkins long-polling and
    # SSE build-log streams mid-request. 4000s is the ALB maximum.
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=4000
    # Envoy answers "/" with 404 when no HTTPRoute matches it; that 404 still
    # proves the proxy is alive, so accept it as healthy.
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/success-codes: '200-404'
    alb.ingress.kubernetes.io/tags: cb-user=${TAG_CB_USER:-acaternberg},cb-owner=${TAG_CB_OWNER:-professional-services},cb-environment=${TAG_CB_ENVIRONMENT:-demo}
spec:
  ingressClassName: alb
  rules:
  - host: ${CJOC_HOST_NAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${ENVOY_SVC}
            port:
              number: 443
EOF

log "Waiting for the ALB to be provisioned (a few minutes)..."
ALB_DNS=""
for _ in $(seq 1 60); do
  ALB_DNS=$(kubectl get ingress cjoc-alb -n "${ENVOY_GW_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${ALB_DNS}" ]] && break
  echo 'wait for LB creation'
  sleep 20
done
echo

if [[ -n "${ALB_DNS}" ]]; then
  success "ALB provisioned: ${ALB_DNS}"
  log "external-dns (06-installExternalDNS.sh) will point ${CJOC_HOST_NAME} at it."
else
  error "ALB was not provisioned. Check: kubectl describe ingress cjoc-alb -n ${ENVOY_GW_NAMESPACE}"
fi

success "Installation completed successfully."