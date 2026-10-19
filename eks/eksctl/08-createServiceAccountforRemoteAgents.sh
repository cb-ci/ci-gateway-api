#!/bin/bash
set -euo pipefail

NAMESPACE=cbci-builds

# --dry-run=client -o yaml | kubectl apply -f -  makes these safe to re-run
# (kubectl create alone errors with AlreadyExists on a second run).
kubectl create serviceaccount jenkins-agent -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create role jenkins-agent-role -n "$NAMESPACE" \
  --verb=get,list,watch,create,delete,update,patch \
  --resource=pods,pods/log,pods/exec,events,persistentvolumeclaims \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create rolebinding jenkins-agent-binding -n "$NAMESPACE" \
  --role=jenkins-agent-role --serviceaccount="$NAMESPACE":jenkins-agent \
  --dry-run=client -o yaml | kubectl apply -f -

# For the token, a plain kubectl create token expires (bound by the API server's max-token-expiration) and Jenkins won't auto-refresh a pasted Secret Text credential. For something that doesn't silently expire
# on you, create a legacy-style Secret instead:
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-agent-token
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: jenkins-agent
type: kubernetes.io/service-account-token
EOF

kubectl get secret jenkins-agent-token -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d
echo