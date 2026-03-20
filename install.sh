#!/bin/bash
NAMESPACE=cloudbees-gatewayapi
GATEWAY_NAME=cloudbees-gateway
CJOC_HOST_NAME=gateway.acaternberg.flow-training.beescloud.com

REGION=us-east1 && MACHINE_TYPE=n1-standard-8
CLUSTER_NAME=cb-ci
ZONE=us-east1-d
set -x

# Enable gateway API
gcloud container clusters update $CLUSTER_NAME \
     --gateway-api=standard \
     --zone $ZONE 
# Enable certificate manager. We dont use it in this examples, we use self signed certs
# gcloud services enable certificatemanager.googleapis.com

# Create a proxy only subnet for the gateway. Not sure , if we realy ned this
gcloud compute networks subnets create proxy-only-subnet \
  --purpose=REGIONAL_MANAGED_PROXY \
  --role=ACTIVE \
  --region=$REGION \
  --network=default \
  --range=10.10.0.0/23 || true

# Create a self signed cert
# ./generate-self-signed-cert.sh

# Create namespace to deploy cloudbees core and gateway api resources
kubectl create namespace $NAMESPACE || true

# Create a secret with the self signed cert
CERT_NAME=acaternberg-cert-selfsigned
kubectl delete secret $CERT_NAME -n $NAMESPACE || true
kubectl create secret tls $CERT_NAME --cert="./jenkins.pem" --key="./server.key" -n $NAMESPACE || exit 1

# Get gateway classes, CRDs and gateway
kubectl get gatewayclasses
kubectl get crd | grep gateway.networking.k8s.io


# Create a gateway and bind it to the cloudbees-gatewayapi namespace
# gatewayClassName: gke-l7-gxlb # gke-l7-regional-external-managed
#kubectl delete gateway $GATEWAY_NAME -n $NAMESPACE || true
cat <<EOF | kubectl apply -f -
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: $GATEWAY_NAME
  namespace: $NAMESPACE
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
spec: 
  gatewayClassName: gke-l7-regional-external-managed
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: $CERT_NAME
    allowedRoutes:
      namespaces:
        from: All
EOF



# Apply health check policy for cjoc
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: cjoc-health-check-policy
  namespace: $NAMESPACE
spec:
  default:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /cjoc/health/
    logConfig:
      enabled: true
  targetRef:
    group: ""
    kind: Service
    name: cjoc
EOF

#Apply health check policy for Controller 
export CONTROLLER_NAME=ha
export SERVICE_NAME=ha
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: $CONTROLLER_NAME-health-check-policy
  namespace: cloudbees-gatewayapi
spec:
  default:
    checkIntervalSec: 10
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: /$CONTROLLER_NAME/health/
    logConfig:
      enabled: true
  targetRef:
    group: ""
    kind: Service
    name: $SERVICE_NAME
EOF


# Enable sticky sessions for ha controller 
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: cloudbees-sticky-policy
  namespace: cloudbees-gatewayapi
spec:
  default:
    sessionAffinity:
      type: GENERATED_COOKIE
      cookieTtlSec: 3600
    connectionDraining:
      drainingTimeoutSec: 60
  targetRef:
    group: ""
    kind: Service
    name: $SERVICE_NAME
EOF

# cat <<EOF | kubectl apply -f -
# apiVersion: networking.gke.io/v1
# kind: GCPBackendPolicy
# metadata:
#   name: cloudbees-sticky-policy
#   namespace: cloudbees-gatewayapi
# spec:
#   default:
#     sessionPersistence:
#       sessionAffinity: HTTP_COOKIE
#       httpCookie:
#         name: "cloudbees-sticky-session"
#         ttl: "3600s" # 1 hour
#     # Required for HTTP_COOKIE to function correctly
#     localityLbAlgorithm: MAGLEV
#   targetRef:
#     group: ""
#     kind: Service
#     name: ha
# EOF



helm repo update 

helm upgrade --install cloudbees-core-gwapi cloudbees/cloudbees-core \
  --namespace $NAMESPACE \
  --set Gateway.Enabled=true \
  --set OperationsCenter.Gateway.Name=$GATEWAY_NAME \
  --set OperationsCenter.Gateway.SectionName=https \
  --set OperationsCenter.Gateway.Namespace=$NAMESPACE \
  --set OperationsCenter.HostName=$CJOC_HOST_NAME \
  --set OperationsCenter.Protocol=https \
  --set Agents.SeparateNamespace.Enabled=false \
  --set Common.image.tag='latest' \
  --create-namespace

# Get the gateway and check the status, wait a while for IP and adjustr the CLOUD_DNS A record to point to the gateway IP
kubectl get gateway $GATEWAY_NAME -n $NAMESPACE

