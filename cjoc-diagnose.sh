#!/usr/bin/env bash
# Read-only diagnostics for a crash-looping cjoc-0. No cluster writes.
# Usage: NS=cbci ./cjoc-diagnose.sh [> cjoc-diag.txt]
set -uo pipefail

NS="${NS:-cbci}"
POD="${POD:-cjoc-0}"
CONTAINER="${CONTAINER:-jenkins}"
STS="${STS:-cjoc}"

section() { printf '\n===== %s =====\n' "$1"; }

section "Pod status"
kubectl get pod "$POD" -n "$NS" -o wide

section "Image ID(s) actually running"
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\t"}restarts={.restartCount}{"\n"}{end}'

section "Last termination state"
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState}{"\n"}{end}'

section "Container image, resources, probes"
if command -v jq >/dev/null 2>&1; then
  kubectl get sts "$STS" -n "$NS" -o json \
    | jq --arg c "$CONTAINER" '.spec.template.spec.containers[] | select(.name==$c)
        | {image, imagePullPolicy, resources, startupProbe, livenessProbe, readinessProbe}'
else
  kubectl get sts "$STS" -n "$NS" -o yaml | grep -n -E 'image:|imagePullPolicy|Probe|failureThreshold|periodSeconds|initialDelaySeconds|timeoutSeconds|cpu:|memory:'
fi

section "PVCs"
kubectl get pvc -n "$NS"

section "Recent events for $POD"
kubectl get events -n "$NS" --field-selector "involvedObject.name=$POD" --sort-by=.lastTimestamp | tail -25

section "Previous run: key log lines (redact before sharing)"
kubectl logs "$POD" -n "$NS" -c "$CONTAINER" --previous 2>&1 \
  | grep -n -E 'Jenkins is fully up|Version:|SEVERE|WARNING|Failed|Exception|CasC|bundle|Migrat|plugin' \
  | head -60

section "Previous run: first 80 lines (redact before sharing)"
kubectl logs "$POD" -n "$NS" -c "$CONTAINER" --previous 2>&1 | head -80
