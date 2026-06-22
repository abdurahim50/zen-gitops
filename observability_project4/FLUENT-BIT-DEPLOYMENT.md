# Fluent Bit Deployment Guide (ArgoCD — `pharma` Project)

## Overview

Fluent Bit runs as a **DaemonSet** on every EKS node. It tails `/var/log/containers/*.log`, enriches
logs with Kubernetes metadata, derives a `_service_name` field via a Lua script, and ships logs to
**Elastic Cloud** over TLS on port 443.

ArgoCD (project: `pharma`) manages the Helm chart at `helm-charts-fluent-bit/` using the
env-specific values file at `envs/dev/values-fluent-bit.yaml`.

---

## Architecture

```
EKS Node
└── /var/log/containers/*.log
        │
        ▼
  Fluent Bit DaemonSet (namespace: dev)
        │  tail → kubernetes filter → grep(dev) → lua(service_name)
        ▼
  Elastic Cloud (GCP us-central1)
  https://my-elasticsearch-project-be5821.es.us-central1.gcp.elastic.cloud:443
        │
        ▼
  Index pattern:  <service-name>-YYYY.MM.DD
```

---

## Pre-requisites

- EKS cluster running with `dev` namespace created
- ArgoCD installed in the `argocd` namespace
- `kubectl` configured to the target cluster
- Elastic Cloud deployment active at:
  `https://my-elasticsearch-project-be5821.es.us-central1.gcp.elastic.cloud:443`

---

## Step 1 — Create Elasticsearch on Elastic Cloud

1. Log in at <https://cloud.elastic.co/>
2. Click **Create deployment** → choose **Elasticsearch**
3. Select cloud provider **GCP**, region **us-central1**
4. Copy the **Cloud endpoint** after creation:
   ```
   https://my-elasticsearch-project-be5821.es.us-central1.gcp.elastic.cloud:443
   ```

---

## Step 2 — Create an API Key

1. In your deployment go to **Security → API Keys → Create API key**
2. Name it `fluent-bit-dev`, set no expiry
3. Under **Restrict privileges**, grant `write` and `auto_configure` on index pattern `*`
4. Copy the **Encoded** value (base64 format) — this is what goes into the Kubernetes secret

---

## Step 3 — Create the Kubernetes Secret

The DaemonSet reads `ELASTIC_API_KEY` from this secret at startup. It is **not** managed by
ArgoCD — create it manually once per cluster before syncing.

```bash
kubectl create secret generic fluent-bit-elastic-credentials \
  --namespace dev \
  --from-literal=api_key='Y2xZRzc1NEJhZjZzUnhfam0wdHo6bExaQjdqQUw4aGJtbzFCdEp0SEh6UQ==' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret fluent-bit-elastic-credentials -n dev
kubectl describe secret fluent-bit-elastic-credentials -n dev
```

> The manifest `k8s/fluent-bit/secret.yaml` also reflects this key and can be applied directly:
> ```bash
> kubectl apply -f k8s/fluent-bit/secret.yaml
> ```

---

## Step 4 — Apply the ArgoCD Project

The `pharma` AppProject authorises the `DPP-2026/zen-gitops` source repo and grants access to
the `dev`, `qa`, `prod`, `argocd`, `monitoring`, and `kube-system` namespaces.

```bash
kubectl apply -f argocd/projects/pharma-project.yaml
```

---

## Step 5 — Apply the ArgoCD Application

```bash
kubectl apply -f observability_project4/fluent-bit-app.yaml
```

ArgoCD will sync `helm-charts-fluent-bit/` (branch: `feature/fluent-bit-logging`) using
`envs/dev/values-fluent-bit.yaml` as the override values file.

Monitor sync status:

```bash
argocd app get fluent-bit-dev
argocd app sync fluent-bit-dev   # force sync if needed
```

---

## Step 6 — Apply Raw Manifests (kubectl path, optional)

Use this instead of the ArgoCD path for a direct one-shot deploy:

```bash
kubectl apply -f k8s/fluent-bit/rbac.yaml
kubectl apply -f k8s/fluent-bit/configmap.yaml
kubectl apply -f k8s/fluent-bit/daemonset.yaml
```

---

## Verification

### Check Pods Are Running

```bash
kubectl get pods -n dev -l app=fluent-bit
kubectl logs -n dev -l app=fluent-bit --tail=50
```

Expected: one pod per node, all `Running 1/1`.

### Health and Metrics Endpoints

```bash
kubectl port-forward -n dev ds/fluent-bit 2020:2020
curl http://localhost:2020/api/v1/health
curl http://localhost:2020/api/v1/metrics/prometheus
```

### Confirm Logs Are in Elastic Cloud

- Go to **Elastic Cloud → Discover**
- Create an index pattern: `dev-service-*` or `<service-name>-*`
- Logs should appear within ~1 minute of pods starting

### Prometheus Metrics

The DaemonSet pods expose metrics on port `2020`. Apply the PodMonitor to scrape them:

```bash
kubectl apply -f k8s/monitoring/fluent-bit-podmonitor.yaml
```

---

## File Reference

| File | Purpose |
|------|---------|
| `observability_project4/fluent-bit-app.yaml` | ArgoCD Application manifest |
| `observability_project4/README.md` | Quick-start guide |
| `helm-charts-fluent-bit/Chart.yaml` | Helm chart definition |
| `helm-charts-fluent-bit/values.yaml` | Default Helm values |
| `envs/dev/values-fluent-bit.yaml` | Dev-env overrides (ES host, namespace, resources) |
| `helm-charts-fluent-bit/templates/configmap.yaml` | Helm-templated Fluent Bit config |
| `helm-charts-fluent-bit/templates/daemonset.yaml` | DaemonSet template |
| `helm-charts-fluent-bit/templates/rbac.yaml` | ServiceAccount + ClusterRole |
| `k8s/fluent-bit/configmap.yaml` | Raw ConfigMap (includes Lua service_index script) |
| `k8s/fluent-bit/daemonset.yaml` | Raw DaemonSet manifest |
| `k8s/fluent-bit/rbac.yaml` | Raw RBAC manifests |
| `k8s/fluent-bit/secret.yaml` | Elastic API key secret (current key) |
| `k8s/monitoring/fluent-bit-podmonitor.yaml` | Prometheus PodMonitor |
| `argocd/projects/pharma-project.yaml` | ArgoCD AppProject |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pods in `CreateContainerConfigError` | Secret `fluent-bit-elastic-credentials` missing | Run Step 3 |
| `[error] [engine] output initialization failed` | Invalid config parameter in `[OUTPUT]` block | Check configmap for unsupported keys (`http_api_key` is correct for Fluent Bit 5.x) |
| `401 Unauthorized` from Elastic | Wrong or expired API key in secret | Re-create secret with a new API key from Elastic Cloud |
| No indices in Elastic Cloud | Logs filtered out by namespace grep or wrong ES host | Check pod logs; verify `host` in `envs/dev/values-fluent-bit.yaml` |
| ArgoCD sync error: `application repo not permitted` | Source repo not in AppProject | Re-apply `argocd/projects/pharma-project.yaml` |
| ArgoCD sync error: `revision not found` | Branch `feature/fluent-bit-logging` not pushed | Push branch or update `targetRevision` in `fluent-bit-app.yaml` |
| No metrics in Prometheus | PodMonitor not applied | `kubectl apply -f k8s/monitoring/fluent-bit-podmonitor.yaml` |
