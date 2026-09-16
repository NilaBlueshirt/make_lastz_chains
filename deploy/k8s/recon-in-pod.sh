#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Read-only reconnaissance from INSIDE a pod. Answers the questions that are
# invisible from the outside: egress, DNS, FUSE, node-local disk.
#
# Run it against any already-running pod — it needs nothing but bash:
#
#   kubectl exec deploy/hello-world -- bash -s < deploy/k8s/recon-in-pod.sh
#
# To also test the helios endpoint, pass it in:
#
#   kubectl exec deploy/hello-world -- \
#     env HELIOS=your-endpoint.asu.edu bash -s < deploy/k8s/recon-in-pod.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HELIOS="${HELIOS:-}"

hdr() { printf '\n\n== %s ==\n' "$*"; }

# TCP reachability using only bash builtins — works in any image, no curl needed.
tcp() {
    local host=$1 port=${2:-443}
    if timeout 8 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
        printf '  %-32s TCP %-5s OPEN\n' "$host" "$port"
    else
        printf '  %-32s TCP %-5s BLOCKED or unresolvable\n' "$host" "$port"
    fi
}

# Full TLS + HTTP check, if the image happens to have curl.
https() {
    local url=$1
    if command -v curl >/dev/null 2>&1; then
        printf '  %-40s %s\n' "$url" \
          "$(curl -s -o /dev/null -w '%{http_code} (tls:%{ssl_verify_result})' \
             --max-time 12 "$url" 2>&1 || echo FAILED)"
    fi
}

hdr "0. Where am I"
echo "  hostname (pod name): $(hostname)"
echo "  node:                ${NODE_NAME:-<not exposed>}"
echo "  os:                  $(cat /etc/os-release 2>/dev/null | grep PRETTY | cut -d= -f2-)"
echo "  visible CPUs:        $(nproc 2>/dev/null)"
echo "  tools present:       $(for t in curl wget openssl dig getent nslookup; do
                                 command -v $t >/dev/null 2>&1 && printf '%s ' $t; done)"

hdr "1. FUSE — can a Fusion mount work here"
# /dev/fuse present in an unprivileged pod means a device plugin is exposing it,
# which is the non-privileged Fusion route. Absent is the normal default and
# says nothing on its own — the real test is whether a privileged pod is allowed.
if [ -e /dev/fuse ]; then
    echo "  /dev/fuse EXISTS  →  $(ls -l /dev/fuse)"
else
    echo "  /dev/fuse absent (expected in an unprivileged pod)"
fi
echo "  fuse in kernel modules: $(grep -c fuse /proc/filesystems 2>/dev/null) match(es)"
grep fuse /proc/filesystems 2>/dev/null | sed 's/^/    /'

hdr "2. Node-local disk — sizes the Fusion cache emptyDir"
df -h / /tmp /dev/shm 2>/dev/null | sed 's/^/  /'
echo "  (the filesystem behind /tmp is the node's disk unless a volume is mounted)"

hdr "3. Memory + CPU actually enforced on this container (cgroup limits)"
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes \
         /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu/cpu.cfs_quota_us; do
    [ -r "$f" ] && echo "  $f = $(cat $f)"
done

hdr "4. DNS"
for h in github.com wave.seqera.io ghcr.io quay.io kubernetes.default.svc; do
    if command -v getent >/dev/null 2>&1; then
        printf '  %-32s %s\n' "$h" "$(getent hosts "$h" 2>/dev/null | head -1 || echo 'NO RESOLUTION')"
    fi
done
echo "  resolv.conf:"; sed 's/^/    /' /etc/resolv.conf 2>/dev/null

hdr "5. Egress — everything the Nextflow driver needs to reach"
echo "  github.com     : pipeline source pulled by 'nextflow run hillerlab/...'"
tcp github.com 443
echo "  wave.seqera.io : injects the Fusion client into the pipeline image"
tcp wave.seqera.io 443
echo "  fusionfs.seqera.io : Fusion client download"
tcp fusionfs.seqera.io 443
echo "  ghcr.io        : the make_lastz_chains image"
tcp ghcr.io 443
echo "  quay.io        : per-module biocontainer images"
tcp quay.io 443
echo "  registry-1.docker.io : the nextflow/nextflow driver image"
tcp registry-1.docker.io 443

hdr "5b. Full TLS handshake (only runs if curl exists — catches MITM proxies)"
https https://github.com
https https://wave.seqera.io
https https://ghcr.io/v2/

hdr "6. Proxy environment (a university cluster may require one)"
env | grep -iE '^(http|https|no|ftp)_proxy|^(HTTP|HTTPS|NO|FTP)_PROXY' || echo "  none set"

hdr "7. helios S3 endpoint"
if [ -n "$HELIOS" ]; then
    host="${HELIOS#*://}"; host="${host%%/*}"; port="${host##*:}"
    [ "$port" = "$host" ] && port=443 || host="${host%%:*}"
    tcp "$host" "$port"
    https "https://$host"
else
    echo "  skipped — rerun with:  env HELIOS=<endpoint> bash -s < recon-in-pod.sh"
fi

hdr "8. Kubernetes API reachability + mounted service account"
SA=/var/run/secrets/kubernetes.io/serviceaccount
if [ -d "$SA" ]; then
    echo "  service account token mounted; namespace = $(cat $SA/namespace 2>/dev/null)"
else
    echo "  no service account token mounted"
fi
tcp kubernetes.default.svc 443

echo
echo "== DONE =="
