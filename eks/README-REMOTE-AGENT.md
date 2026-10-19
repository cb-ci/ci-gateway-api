# Configuring a Jenkins Kubernetes Cloud for the Remote EC2 Client Controller

A Jenkins Kubernetes Cloud needs four things: the API server URL, the
cluster's CA certificate, a namespace to provision agent pods in, and a
credential Jenkins can authenticate with.

Since the Client Controller runs on EC2 — outside the cluster — the simplest
path is a dedicated ServiceAccount with a long-lived token, not a kubeconfig
with `exec`-based IAM auth. The token approach avoids IAM/`aws-auth`
entanglement entirely.

## 1. API server URL

```sh
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} \
  --query 'cluster.endpoint' --output text
```

## 2. Cluster CA certificate

Goes in the "Kubernetes server certificate key" field so Jenkins trusts the
API server's TLS cert instead of you having to disable verification:

```sh
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} \
  --query 'cluster.certificateAuthority.data' --output text | base64 -d
```

Paste the PEM output as-is.

## 3. Namespace

Whatever namespace agent pods should land in — check what the CloudBees CI
chart actually created (`Agents.SeparateNamespace.Enabled` / `.Create=true`
from `05-inatallCloudBees.sh` names this itself; don't guess, confirm with
`kubectl get ns`).

## 4. ServiceAccount, RBAC, and token

Run against the cluster from a machine with cluster-admin `kubectl` access —
your own workstation, not the EC2 box:

```sh
NAMESPACE=<the agents namespace from step 3>

kubectl create serviceaccount jenkins-agent -n "$NAMESPACE"

kubectl create role jenkins-agent-role -n "$NAMESPACE" \
  --verb=get,list,watch,create,delete,update,patch \
  --resource=pods,pods/log,pods/exec,events,persistentvolumeclaims

kubectl create rolebinding jenkins-agent-binding -n "$NAMESPACE" \
  --role=jenkins-agent-role --serviceaccount="$NAMESPACE":jenkins-agent
```

A plain `kubectl create token` expires (bound by the API server's
max-token-expiration), and Jenkins won't auto-refresh a pasted Secret Text
credential. For a token that doesn't silently expire on you, create a
legacy-style Secret instead:

```sh
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
```

This is scripted end-to-end in `eksctl/08-createServiceAccountforRemoteAgents.sh`
(bash) and `tf/02-platform/remote_agents.tf` (Terraform) — either one produces
the same ServiceAccount/Role/RoleBinding/token.

## 5. Wire it into Jenkins

On the Client Controller (EC2-hosted): **Manage Jenkins → Clouds → New Cloud
→ Kubernetes**

- **Kubernetes URL**: output of step 1
- **Kubernetes server certificate key**: output of step 2
- **Namespace**: from step 3
- **Credentials** → Add → Jenkins → Kind **Secret text** → paste the token
  from step 4 → select it in the Cloud config
- Click **Test Connection**

Network path is already handled — the security group rule added earlier lets
this EC2 instance reach the API server on 443, which "Test Connection"
exercises.

## Alternative: authenticate as the EC2 instance's IAM identity

If you'd rather use a full kubeconfig (`aws eks get-token`) instead of a
static token, the EC2 instance's IAM role needs `eks:DescribeCluster` and a
mapping into the cluster's `aws-auth` ConfigMap or EKS access entries, plus
the same RBAC binding as above. That's more moving parts than the token
approach — only worth it if you have a specific reason to avoid long-lived
static tokens.
