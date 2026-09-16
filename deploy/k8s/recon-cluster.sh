#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Read-only reconnaissance of a Kubernetes cluster, aimed at the specific
# questions the make_lastz_chains manifests in this directory cannot answer
# from outside.
#
#   ./recon-cluster.sh [namespace]
#
# Nothing here creates, modifies or deletes anything. Failures are expected and
# non-fatal — a command erroring out ("Forbidden", "not found") IS a result.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # deliberately not -e: keep going past permission errors

NS="${1:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)}"
NS="${NS:-default}"

hdr() { printf '\n\n\033[1m══ %s ══\033[0m\n' "$*"; }
sub() { printf '\n\033[36m→ %s\033[0m\n' "$*"; }

echo "namespace under test: $NS"

# ─────────────────────────────────────────────────────────────────────────────
hdr "1. Who am I, and what cluster is this"
# Decides: whether this is vanilla k8s or OpenShift (OpenShift uses SCCs
# instead of PSA and almost never allows privileged pods).
sub "client / server version"
kubectl version 2>&1 | head -20
sub "current context"
kubectl config current-context 2>&1
sub "my identity"
kubectl auth whoami 2>&1 | head -20
sub "OpenShift? (error here = plain Kubernetes, which is good news)"
kubectl get clusterversion 2>&1 | head -5

# ─────────────────────────────────────────────────────────────────────────────
hdr "2. What am I allowed to do"
# Decides: whether 00-namespace.yaml and 01-rbac.yaml are usable as written, or
# whether you must work inside a namespace an admin gives you.
for check in \
    "create namespaces" \
    "create pods --namespace $NS" \
    "delete pods --namespace $NS" \
    "get pods/log --namespace $NS" \
    "create jobs --namespace $NS" \
    "create serviceaccounts --namespace $NS" \
    "create roles --namespace $NS" \
    "create rolebindings --namespace $NS" \
    "create secrets --namespace $NS" \
    "create configmaps --namespace $NS" \
    "create persistentvolumeclaims --namespace $NS" \
    "list nodes"
do
    printf '  %-50s %s\n' "$check" "$(kubectl auth can-i $check 2>&1 | tail -1)"
done

# ─────────────────────────────────────────────────────────────────────────────
hdr "3. Pod Security — THE decisive one for Fusion"
# Decides: fusion.privileged in 03-configmap.yaml. Fusion needs a FUSE mount.
# If PSA enforce is 'baseline' or 'restricted', privileged pods are rejected
# outright and you need the k8s-fuse-plugin route instead.
sub "PSA labels on namespace $NS (look for pod-security.kubernetes.io/enforce)"
kubectl get ns "$NS" -o jsonpath='{.metadata.labels}' 2>&1 | tr ',' '\n'
echo
sub "PSA labels across all namespaces"
kubectl get ns -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce,AUDIT:.metadata.labels.pod-security\.kubernetes\.io/audit' 2>&1 | head -30
sub "policy engines (Kyverno / Gatekeeper) — these can block privileged too"
kubectl get clusterpolicies.kyverno.io 2>&1 | head -20
kubectl get constrainttemplates 2>&1 | head -20
sub "OpenShift SecurityContextConstraints, if applicable"
kubectl get scc 2>&1 | head -20
sub "RuntimeClasses (gVisor/Kata would also rule out FUSE)"
kubectl get runtimeclass 2>&1 | head -10

# ─────────────────────────────────────────────────────────────────────────────
hdr "4. Is a FUSE device plugin already installed"
# Decides: whether you can run Fusion *without* privilege. If any node
# advertises a fuse device in its allocatable resources, you're in luck.
sub "DaemonSets cluster-wide (looking for anything fuse-related)"
kubectl get daemonsets -A 2>&1 | head -40
sub "nodes advertising a FUSE device resource"
kubectl get nodes -o json 2>/dev/null \
  | grep -iE '"(nextflow\.io/fuse|.*fuse.*)"' | sort -u | head -10 \
  || echo "  (none found)"

# ─────────────────────────────────────────────────────────────────────────────
hdr "5. Node shape — sanity-check the 152 CPU / 500 GB assumption"
# Decides: process.resourceLimits and the LASTZ memory/density tuning.
# 'Allocatable' is what you can actually request — always less than 'Capacity',
# because the kubelet and system daemons reserve some.
sub "nodes"
kubectl get nodes -o wide 2>&1 | head -30
sub "allocatable per node (cpu / memory / ephemeral-storage / max pods)"
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,DISK:.status.allocatable.ephemeral-storage,PODS:.status.allocatable.pods' 2>&1 | head -30
sub "node labels — useful for a nodeSelector later"
kubectl get nodes --show-labels 2>&1 | head -10
sub "taints (a tainted node needs a matching toleration or nothing schedules)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints' 2>&1 | head -30
sub "current utilisation (needs metrics-server; error is fine)"
kubectl top nodes 2>&1 | head -20

# ─────────────────────────────────────────────────────────────────────────────
hdr "6. Storage"
# Decides: 04-driver-pvc.yaml. Need one RWO class for the driver's resume
# cache. An RWX class would be a bonus but is not required by this design.
sub "storage classes (look for '(default)' and note the provisioner)"
kubectl get storageclass 2>&1
sub "access modes each provisioner supports is NOT in the API — check the"
echo "  provisioner names above: 'nfs'/'cephfs'/'azurefile' imply RWX is possible;"
echo "  'local-path'/'*-csi' block drivers are RWO-only."
sub "existing PVs, if any"
kubectl get pv 2>&1 | head -20
sub "CSI drivers installed"
kubectl get csidrivers 2>&1 | head -20

# ─────────────────────────────────────────────────────────────────────────────
hdr "7. Quotas and limits in namespace $NS"
# Decides: whether executor.queueSize = 500 is even reachable. A ResourceQuota
# capping pods or total CPU silently throttles the whole pipeline.
sub "resource quotas"
kubectl get resourcequota -n "$NS" -o yaml 2>&1 | grep -A30 -E '^\s+(hard|used):' | head -40
kubectl get resourcequota -n "$NS" 2>&1 | head -10
sub "limit ranges (these inject default requests/limits into your pods)"
kubectl get limitrange -n "$NS" -o yaml 2>&1 | grep -A20 'limits:' | head -30
kubectl get limitrange -n "$NS" 2>&1 | head -10

# ─────────────────────────────────────────────────────────────────────────────
hdr "8. What is already running in $NS"
kubectl get all -n "$NS" 2>&1 | head -30

hdr "DONE"
echo "Next: run the in-pod checks against a running pod, e.g."
echo "  kubectl exec -n $NS deploy/hello-world -- bash -s < deploy/k8s/recon-in-pod.sh"
