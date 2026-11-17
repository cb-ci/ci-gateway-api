#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# _nodepools-lib.sh — Node pool definitions shared by the 00-*NodePools.sh
# scripts. Mirrors the three managed node groups in eks/eksctl/eksctl-config.yaml.tpl.
#
#   pool         purpose                                    taint
#   controllers  CloudBees CI controller pods (CJOC, MCs)   workload=controller:NoSchedule
#   agents       build agent pods                           workload=agent:NoSchedule
#   system       cluster add-ons (kube-dns, Envoy Gateway…) none
#
# `system` is deliberately untainted: with `controllers` and `agents` both
# tainted, add-on Deployments without a toleration would otherwise have no node.
#
# DIFFERENCES FROM EKS
#   - controllers is x86_64 here (EKS uses Graviton m7g); GKE has no like-for-like
#     ARM64 default, so e2/n2 is used. Override with CONTROLLERS_MACHINE_TYPE.
#   - Autoscaling is GKE's built-in node autoscaler per pool (no cluster-autoscaler
#     Deployment to install). In a zonal cluster min/max are per pool.
#   - Private nodes are a cluster-level setting in GKE, not per pool.
#
# Every value can be overridden from gke/.env (see gke/.env-template).
# -----------------------------------------------------------------------------

NODEPOOL_MIN="${NODEPOOL_MIN:-1}"
NODEPOOL_DESIRED="${NODEPOOL_DESIRED:-1}"
NODEPOOL_MAX="${NODEPOOL_MAX:-2}"
NODEPOOL_DISK_TYPE="${NODEPOOL_DISK_TYPE:-pd-balanced}"

# name|machine type|disk GB|workload label value|tainted (true/false)
NODEPOOLS=(
  "controllers|${CONTROLLERS_MACHINE_TYPE:-e2-standard-4}|${CONTROLLERS_DISK_GB:-80}|controller|true"
  "agents|${AGENTS_MACHINE_TYPE:-e2-standard-4}|${AGENTS_DISK_GB:-100}|agent|true"
  "system|${SYSTEM_MACHINE_TYPE:-e2-standard-2}|${SYSTEM_DISK_GB:-60}|system|false"
)

STATE_FILE="${NODEPOOL_STATE_FILE:-${SCRIPT_DIR}/.nodepool-scale-state.json}"

# gcloud flags shared by every node-pool call.
gke_target_args() { printf '%s\n' --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" --zone "${ZONE}"; }

# Prints the command instead of running it when DRY_RUN=true.
run() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    printf '[DRY-RUN] %q ' "$@"; echo
  else
    "$@"
  fi
}

nodepool_exists() {
  gcloud container node-pools describe "$1" \
    --project "${PROJECT_ID}" --cluster "${CLUSTER_NAME}" --zone "${ZONE}" \
    --format='value(name)' &>/dev/null
}

confirm() {
  [[ "${ASSUME_YES:-false}" == true ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
}
