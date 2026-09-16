# Running make_lastz_chains on Kubernetes

Pod-per-task execution with the Nextflow `k8s` executor, the Fusion file system,
and the **helios** S3 bucket as the work directory. No shared POSIX filesystem
and no ReadWriteMany PVC required.

## How it fits together

```
  mlc-driver Job ──── creates one Pod per task ───▶  LASTZ pod   (1 cpu, 12 Gi)
  (Nextflow head)          via the k8s API           LASTZ pod   (1 cpu, 12 Gi)
        │                                            AXT_CHAIN   (8 cpu, 50 Gi)
        │                                            CHAINC      (8 cpu, 80 Gi)
        │                                                 │
        └──── reads/writes s3://<bucket>/mlc-work ────────┘
                    via Fusion (FUSE), cached on
                    each node's local disk at /tmp
```

Fusion is the piece that removes the shared-filesystem requirement. It mounts
the S3 work directory into each task pod and fetches only the bytes a task
actually reads, caching them on node-local disk. That laziness matters here:
`EXTRACT_CHROMS` emits a directory of per-chromosome FASTAs that *every* LASTZ
task takes as an input, and LASTZ only ever opens two of them. A stage-in-based
executor would copy both whole genomes into every task.

## Before you start

Run the recon scripts first — they answer everything below with facts instead
of assumptions:

```bash
./deploy/k8s/recon-cluster.sh [namespace]                  # from your laptop
kubectl exec deploy/<any-running-pod> -- bash -s \
    < deploy/k8s/recon-in-pod.sh                           # from inside the cluster
```

Two things they check that can block the whole approach:

**1. Privileged pods.** Fusion is a FUSE mount and by default Nextflow marks
every task pod privileged. Clusters running Pod Security Admission at
`baseline` or `restricted` will reject them. The fix is the
[k8s-fuse-plugin](https://github.com/nextflow-io/k8s-fuse-plugin) DaemonSet plus
`fusion.privileged = false` in `03-configmap.yaml`. Ask about this first.

**2. Egress.** The driver pulls the pipeline from GitHub and calls
`wave.seqera.io` to inject the Fusion client into the pipeline image. On an
air-gapped cluster neither works — see *If Fusion is not an option* below.

## Fill in the placeholders

Every one is spelled `REPLACE_ME_*`; `grep -rn REPLACE_ME deploy/k8s` lists them.

| Placeholder | Where | What it is |
|---|---|---|
| `REPLACE_ME_BUCKET` | `03-configmap.yaml`, `06-smoke-test-job.yaml` | helios bucket name |
| `REPLACE_ME_HELIOS_ENDPOINT` | `03-configmap.yaml` | helios S3 endpoint URL |
| `REPLACE_ME_ACCESS_KEY` / `REPLACE_ME_SECRET_KEY` | `02-secret-helios-s3.yaml.example` | S3 credentials — better to create the Secret imperatively, see that file. The real `02-secret-helios-s3.yaml` is gitignored; copy the template to that name if you must use a file. |
| `REPLACE_ME_REF_NAME` / `REPLACE_ME_QUERY_NAME` | `03-configmap.yaml` | assembly names, e.g. `hg38`, `mm39` |
| `REPLACE_ME_REF.fa` / `REPLACE_ME_QUERY.fa` | `03-configmap.yaml` | the genomes you uploaded to helios |
| `REPLACE_ME_STORAGE_CLASS` | `04-driver-pvc.yaml` | optional; omit to use the default |

## Deploy

```bash
kubectl apply -f deploy/k8s/00-namespace.yaml
kubectl apply -f deploy/k8s/01-rbac.yaml

# Prefer this over filling in a copy of 02-secret-helios-s3.yaml.example:
kubectl -n make-lastz-chains create secret generic helios-s3 \
  --from-literal=AWS_ACCESS_KEY_ID='...' \
  --from-literal=AWS_SECRET_ACCESS_KEY='...'

kubectl apply -f deploy/k8s/03-configmap.yaml

# Smoke test first — toy genomes, a few minutes.
kubectl apply -f deploy/k8s/06-smoke-test-job.yaml
kubectl -n make-lastz-chains logs -f job/mlc-smoke-test

# Then the real run.
kubectl apply -f deploy/k8s/04-driver-pvc.yaml
kubectl apply -f deploy/k8s/05-driver-job.yaml
kubectl -n make-lastz-chains logs -f job/mlc-driver
```

Watch task pods come and go with
`kubectl -n make-lastz-chains get pods -w`.

## What was changed for Kubernetes, and why

The repo's `nextflow.config` is untouched — `03-configmap.yaml` layers an
overlay on top of it with `-c`, so a version bump won't clobber these settings.
The overlay changes four things beyond the executor itself:

- **`publishDir` mode `symlink` → `copy`** for `LASTZ`, `AXT_CHAIN`,
  `CHAINTOOLS_ANTIREPEAT` and `CHAINC`. Symlinks are free on a shared
  filesystem and do not exist on S3. `02_lastz_psl` is the expensive one — it's
  thousands of files; the config says how to switch it off if you don't need
  the raw per-partition alignments.
- **Dropped LASTZ's `beforeScript` sleep.** Upstream staggers job starts by up
  to 60 s to avoid a SLURM prolog storm. The kube-scheduler has no equivalent
  problem, and at this task count the average 30 s is days of aggregate
  wall-clock.
- **LASTZ memory 24 GB → 12 GB.** LASTZ is single-threaded, so memory decides
  how many pods fit per node: at 24 GB only ~20 land on a 500 GB node and 130
  of its 152 cores idle. This is safe to tune because the failure mode
  self-corrects — a Kubernetes OOM-kill exits 137, which is inside the
  pipeline's existing retry range, and `task.attempt` scaling means the retry
  requests 24 GB, then 36. Check `peak_rss` in the trace after your first real
  pair and settle on a number.
- **`process.scratch = false`.** Fusion already gives tasks a node-local view;
  leaving scratch on stages everything twice onto the same disk.

One incidental benefit: the apptainer user-namespace exhaustion that caused
mass LASTZ retries on the SLURM side cannot happen here. Kubernetes runs the
container itself — there is no apptainer in the picture.

## Tuning

`executor.queueSize = 500` is a deliberately conservative start — already about
13 fully-packed nodes. Raise it once you've watched the API server keep up; the
LASTZ stage can absorb thousands of concurrent pods.

`k8s.pod.emptyDir.sizeLimit = 12Gi` should be roughly (node disk budget ÷ pods
per node). With 500 GB per node and ~40 concurrent 12 GB pods, 12 Gi is
comfortable. Pods that exceed it get evicted, so don't cut it close.

The `nodeSelector` and `tolerations` entries in `k8s.pod` are commented out —
uncomment them to confine the pipeline to a specific node pool.

## Verifying it actually works

While a run is live, confirm tasks really are spreading across nodes:

```bash
kubectl -n make-lastz-chains get pods -o wide \
  --field-selector status.phase=Running | awk 'NR>1 {print $7}' | sort | uniq -c
```

After it finishes, the same thing from the trace file — which lands in S3
alongside the results, not on the driver's disk. The overlay adds `hostname`
to `trace.fields` so the column exists:

```bash
aws s3 cp s3://<bucket>/mlc-results/pipeline_info/ . --recursive \
  --endpoint-url https://<helios-endpoint> --exclude '*' --include 'execution_trace_*'
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)if($i=="hostname")c=i; next} {print $c}' \
  execution_trace_*.txt | sort | uniq -c
```

## If Fusion is not an option

If privileged pods are forbidden and the FUSE device plugin isn't available, or
the cluster has no egress to Wave, pod-per-task with S3 doesn't work — the
executor has no way to give tasks a shared view of the work directory.

The fallback is a single fat Pod pinned to one node: 152 CPUs and 500 GB is
enough to run the whole workflow with `-profile local`, work directory on an
`emptyDir`, reading inputs from `s3://` and publishing results back to `s3://`
through Nextflow's own S3 client. It gives up multi-node scaling but needs no
Fusion, no RWX storage, and no privilege. Ask and I'll write that manifest.

## Known unknowns

- **Fusion on an Alpine base image.** The pipeline image is built on
  `python:3.11-alpine` (musl, not glibc). Wave injects the Fusion client as a
  container layer; if that client turns out to be glibc-linked, task pods will
  fail at mount time with a loader error. The smoke test is what tells you.
  Workaround if it bites: rebuild the image on a glibc base (`debian-slim`)
  from `assets/image/Dockerfile`, or fall back to the single-Pod approach.
- **helios endpoint semantics.** `aws.client.s3PathStyleAccess = true` and a
  dummy `region` are set, which is right for MinIO and Ceph RGW. If helios is
  something else, the smoke test will surface it as a 403 or a signature error.
