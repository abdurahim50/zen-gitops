# DevOps Interview Prep — Logging & Monitoring

> Based on the `feature/fluent-bit-logging` branch of the **Zen Pharma GitOps** platform.
> Stack: Fluent Bit → Elasticsearch (Elastic Cloud) · Prometheus → Grafana → Alertmanager · EKS

---

## Table of Contents

1. [Core Concepts — Quick Reference](#1-core-concepts--quick-reference)
2. [Fluent Bit](#2-fluent-bit)
3. [Elasticsearch & Kibana](#3-elasticsearch--kibana)
4. [Prometheus](#4-prometheus)
5. [Grafana & PromQL](#5-grafana--promql)
6. [Alertmanager](#6-alertmanager)
7. [Kubernetes Logging Architecture](#7-kubernetes-logging-architecture)
8. [GitOps & ArgoCD for Observability](#8-gitops--argocd-for-observability)
9. [Scenario-Based Questions](#9-scenario-based-questions)
10. [System Design Questions](#10-system-design-questions)
11. [Quick-Fire Q&A Cheat Sheet](#11-quick-fire-qa-cheat-sheet)

---

## 1. Core Concepts — Quick Reference

### The Two Pillars of Observability

| Pillar | Tool | What it answers |
|--------|------|-----------------|
| **Logs** | Fluent Bit → Elasticsearch | *What happened?* — errors, events, messages |
| **Metrics** | Prometheus → Grafana | *How is it performing?* — CPU, memory, request rates |

### Full Stack Architecture

```
EKS Cluster
│
├── App Pods (api-gateway, auth-service, etc.)
│    ├── write stdout/stderr → /var/log/containers/ on the node
│    └── expose /metrics endpoint
│
├── Fluent Bit DaemonSet (one pod per node)
│    └── tail /var/log/containers/ → enrich → ship → Elasticsearch (Elastic Cloud)
│
├── Prometheus (kube-prometheus-stack)
│    ├── scrapes /metrics from every pod every 15s
│    ├── scrapes Node Exporter (host CPU/disk/mem)
│    ├── scrapes Kube State Metrics (k8s object state)
│    └── evaluates alert rules → fires to Alertmanager
│
├── Grafana
│    └── queries Prometheus via PromQL → renders dashboards
│
└── Alertmanager
     └── groups, deduplicates, routes → Slack / email
```

---

## 2. Fluent Bit

### Q: What is Fluent Bit and why use it over Fluentd or Logstash?

**Answer:**
Fluent Bit is a lightweight, high-performance log processor and forwarder written in C. It is designed for constrained environments like containers and edge devices.

| | Fluent Bit | Fluentd | Logstash |
|-|-----------|---------|----------|
| Language | C | Ruby | JVM |
| Memory footprint | ~1 MB | ~40 MB | ~500 MB+ |
| CPU | Very low | Medium | High |
| Plugin ecosystem | Good | Excellent | Excellent |
| Recommended use | Kubernetes DaemonSet (edge) | Aggregator tier | Heavy ETL |

In this project Fluent Bit runs as a **DaemonSet** (one pod per EKS node) because it needs to read log files directly from the node filesystem at `/var/log/containers/`. Its low footprint means it does not compete with application pods for resources.

---

### Q: Walk me through the Fluent Bit pipeline in this project.

**Answer (five stages):**

```
/var/log/containers/*.log   (every container on the node)
        │
        ▼
[INPUT: tail]
 - Reads new log lines using inotify
 - Tracks read position in a SQLite DB (survives pod restarts)
 - Parses Docker/CRI log format (JSON wrapper + actual log line)
        │
        ▼
[FILTER: kubernetes]
 - Calls the Kubernetes API to enrich each record with:
   pod name, namespace, labels, annotations, node name
        │
        ▼
[FILTER: grep]
 - KEEPS only records where namespace == "dev"
 - DROPS records from the fluent-bit pods themselves
   (avoids recursive log loops)
        │
        ▼
[FILTER: lua]
 - Reads the pod's "app" label (e.g. "api-gateway")
 - Sets _service_name = "api-gateway" on each record
        │
        ▼
[OUTPUT: elasticsearch]
 - Ships over TLS to Elastic Cloud endpoint
 - Authenticates with an API key (from a Kubernetes Secret)
 - Logstash_Prefix_Key _service_name
   → creates one daily index per service:
     api-gateway-2026.05.19
     auth-service-2026.05.19
```

---

### Q: Why does Fluent Bit run as a DaemonSet and not a Deployment?

**Answer:**
Container logs are written to the **node's local filesystem** at `/var/log/containers/`. A Deployment would schedule pods on arbitrary nodes and could not guarantee coverage of every node. A DaemonSet guarantees **exactly one Fluent Bit pod per node**, so every node's logs are collected. Each pod mounts the host path read-only:

```yaml
volumes:
  - name: varlog
    hostPath:
      path: /var/log
```

---

### Q: How does Fluent Bit authenticate to Elastic Cloud?

**Answer:**
The API key is stored in a Kubernetes Secret (`fluent-bit-elastic-credentials`) and injected as an environment variable into the DaemonSet. The ConfigMap references it via `${ELASTIC_API_KEY}`:

```
Secret (base64-encoded api_key)
  → mounted as env var ELASTIC_API_KEY in the DaemonSet pod
    → referenced in fluent-bit.conf: api_key ${ELASTIC_API_KEY}
```

The API key is **never stored in Git** — the Secret is created imperatively with `kubectl create secret`. This is a standard secret hygiene pattern in GitOps: manifests reference secret names, not values.

---

### Q: What RBAC permissions does Fluent Bit need and why?

**Answer:**
The Kubernetes filter needs to call the Kubernetes API server to enrich log records with pod metadata. The ServiceAccount needs:

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
```

Without this, the Kubernetes filter falls back to parsing metadata from the log filename only (which is less reliable). A ClusterRole is used (not a namespaced Role) because Fluent Bit collects logs from all namespaces and needs to look up pods cluster-wide.

---



### Q: What is the Lua filter doing in this pipeline?

**Answer:**
The Lua script (`service_index.lua`) extracts the service name from the pod's `app` label and sets it as `_service_name`. This field is then used by the OUTPUT plugin as the Elasticsearch index prefix:

```lua
function set_service_name(tag, timestamp, record)
    local app = record["kubernetes"]["labels"]["app"]
    if app then
        record["_service_name"] = app
    end
    return 1, timestamp, record
end
```

This means each service gets its own daily index (`api-gateway-2026.05.19`) instead of everything landing in one giant index. This makes Kibana searches faster and enables per-service index lifecycle policies.

---

### Q: What happens if Fluent Bit cannot reach Elasticsearch?

**Answer:**
Fluent Bit has a built-in **retry mechanism** with exponential backoff. Failed records are buffered in memory (or on disk if configured). By default:

- `Retry_Limit 5` — retry up to 5 times before dropping
- The SQLite DB tracks the tail position, so after a restart Fluent Bit resumes from where it left off — no log loss

For production, set `storage.type filesystem` and configure a `storage.path` on a PVC to survive pod restarts with large backlogs.

---

## 3. Elasticsearch & Kibana

### Q: What is Elasticsearch and how does it store logs?

**Answer:**
Elasticsearch is a distributed, RESTful search engine built on Apache Lucene. Logs are stored as **JSON documents** in **indices**. Each document is a single log line enriched with metadata.

In this project, one daily index per service:
```
api-gateway-2026.05.19  →  all api-gateway logs from today
api-gateway-2026.05.18  →  all api-gateway logs from yesterday
```

Elasticsearch inverts the text (tokenises, stems, indexes every word), which is why full-text search across millions of logs is fast.



---

### Q: How would you search for all 500 errors from the api-gateway in the last hour in Kibana?

**Answer:**
In Kibana Discover, using KQL (Kibana Query Language):

```kql
kubernetes.labels.app : "api-gateway" AND http.status_code : 500
```

Or with Lucene syntax:
```
kubernetes.labels.app:"api-gateway" AND http.status_code:500
```

Set the time filter to "Last 1 hour". The index pattern would be `api-gateway-*`.


---

## 4. Prometheus

### Q: What is Prometheus and how does it collect metrics?

**Answer:**
Prometheus is an open-source time-series database and monitoring system. It uses a **pull model** — it reaches out and **scrapes** HTTP endpoints (`/metrics`) on a fixed interval (default 15s). This is the opposite of most older monitoring systems (Nagios, Graphite) which use push.

Why pull is preferred in Kubernetes:
- Prometheus knows exactly which targets it is scraping (and can tell if one disappears)
- No firewall rules needed for inbound connections to the monitored apps
- Scrape failures are immediately visible in Prometheus UI

---

### Q: What is the `/metrics` endpoint?

**Answer:**
It is a plain HTTP endpoint that exposes metrics in **Prometheus text format**:

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 1523
http_requests_total{method="POST",status="500"} 12

# HELP process_memory_bytes Memory in bytes
# TYPE process_memory_bytes gauge
process_memory_bytes 87031808
```

Any application can expose this — Spring Boot uses the `micrometer` library, Node.js uses `prom-client`. Fluent Bit exposes its own pipeline metrics at port 2020.

---



### Q: What is a ServiceMonitor and a PodMonitor?

**Answer:**
Both are Kubernetes CRDs added by the kube-prometheus-stack operator. They tell Prometheus which endpoints to scrape without editing the main Prometheus config.

**ServiceMonitor** — targets a Kubernetes `Service`:
```yaml
kind: ServiceMonitor
spec:
  selector:
    matchLabels:
      app: api-gateway
  endpoints:
    - port: http-metrics
      path: /metrics
```

**PodMonitor** — targets pods directly (used when there is no Service):
```yaml
kind: PodMonitor
spec:
  selector:
    matchLabels:
      app: fluent-bit
  podMetricsEndpoints:
    - path: /api/v1/metrics/prometheus
      port: http
      interval: 30s
```

In this project `k8s/monitoring/fluent-bit-podmonitor.yaml` uses a PodMonitor because Fluent Bit's metrics port is not exposed via a Service.

---

### Q: What are these two flags in the Prometheus values and why are they needed?

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues: false
```

**Answer:**
By default, kube-prometheus-stack only picks up ServiceMonitors/PodMonitors that have labels matching the Helm release label selector. Setting these to `false` makes Prometheus pick up **all** ServiceMonitors and PodMonitors across the entire cluster, regardless of labels.

Without this, the `fluent-bit-podmonitor.yaml` (which lives in the `dev` namespace and was not created by the monitoring Helm release) would be silently ignored.

---

### Q: What is the difference between retention time and retention size in Prometheus?

**Answer:**
Both are configured in this project:
```yaml
prometheusSpec:
  retention: 15d       # delete data older than 15 days
  retentionSize: "8GB" # delete oldest data when total exceeds 8 GB
```

Whichever limit is hit first triggers deletion. `retentionSize` prevents the PVC from filling up even if 15 days of data is less than 8 GB. The Prometheus data PVC (`prometheus-data`) is provisioned at 10 Gi, giving ~2 Gi headroom above the 8 GB cap.

---

### Q: What is kube-state-metrics and how is it different from Node Exporter?

**Answer:**

| | kube-state-metrics | Node Exporter |
|-|-------------------|---------------|
| Exposes | Kubernetes **object** state | Host hardware & OS metrics |
| Examples | Pod restarts, deployment replicas, PVC status | CPU %, disk I/O, network traffic |
| Installed by | kube-prometheus-stack (auto) | kube-prometheus-stack (auto, DaemonSet) |
| Talks to | Kubernetes API server | `/proc`, `/sys` on the host node |

Both are auto-installed by kube-prometheus-stack and auto-scraped by Prometheus.

---

## 5. Grafana & PromQL

### Q: What does Grafana actually store?

**Answer:**
Nothing. Grafana is a **pure visualisation layer**. It stores dashboard definitions (JSON) and data source config, but no metric data. When you open a dashboard:

1. Grafana reads the dashboard JSON (which contains PromQL queries)
2. Fires those queries at Prometheus
3. Prometheus queries its time-series DB and returns numbers
4. Grafana renders those numbers as charts

This is why a Grafana pod restart does not lose any data — all the data lives in Prometheus.

---

### Q: How are dashboards provisioned automatically in this project?

**Answer — two independent streams:**

**Stream 1 — sidecar (28 Kubernetes dashboards)**
```
ConfigMaps labelled grafana_dashboard: "1"
  → grafana-sc-dashboard sidecar container
    watches all namespaces every 60s
      → copies JSON to /tmp/dashboards/
        → loaded into Grafana live (no restart needed)
```



### Q: Write a PromQL query for HTTP error rate as a percentage.

**Answer:**
```promql
100 * (
  sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
)
```

Breaking it down:
- `rate(...[5m])` — per-second rate over the last 5 minutes (smooths spikes)
- `status=~"5.."` — regex match for all 5xx status codes
- `sum()` — aggregate across all pods/instances
- Dividing numerator by denominator gives a ratio; multiply by 100 for percentage

---



## 6. Alertmanager

### Q: What is the role of Alertmanager in the Prometheus stack?

**Answer:**
Alertmanager is responsible for **deduplication, grouping, silencing, and routing** of alerts. Prometheus evaluates alert rules and sends **firing alerts** to Alertmanager. Alertmanager then decides:
- Which receiver to notify (email, Slack, PagerDuty, webhook)
- How to group related alerts (e.g. all alerts from one cluster together)
- When to suppress repeated notifications (`repeat_interval`)
- Which alerts are silenced (maintenance windows)

This separation means Prometheus can fire raw alerts at high frequency, while Alertmanager prevents alert fatigue.

---



## 7. Kubernetes Logging Architecture

### Q: How does Kubernetes handle container logs?

**Answer:**
Kubernetes itself does not ship logs. When a container writes to `stdout`/`stderr`, the container runtime (containerd/Docker) writes those lines to a log file on the **node's filesystem** at:

```
/var/log/containers/<pod-name>_<namespace>_<container-name>-<container-id>.log
```

This is a symlink to:
```
/var/log/pods/<namespace>_<pod-name>_<uid>/<container-name>/<sequence>.log
```

`kubectl logs` reads directly from these files via the kubelet API. Fluent Bit reads from `/var/log/containers/` with the `tail` input plugin.

When a pod is deleted, its log files are deleted too — this is why a log aggregation pipeline (Fluent Bit → Elasticsearch) is essential. Without it, logs disappear with the pod.

---

### Q: What are the two Kubernetes log collection patterns?

**Answer:**

**Pattern 1 — Node-level agent (DaemonSet)**
- One log collector pod per node
- Reads `/var/log/containers/` directly
- Lightweight, no sidecar overhead
- Used in this project: Fluent Bit DaemonSet
- Limitation: only collects stdout/stderr, not application log files inside the container

**Pattern 2 — Sidecar per pod**
- A second container in every pod shares a volume and tails log files
- Can collect application log files (not just stdout/stderr)
- Higher resource cost; harder to manage at scale
- Use when: apps write to files and cannot be reconfigured to log to stdout

---

### Q: What is log rotation in Kubernetes and why does it matter for Fluent Bit?

**Answer:**
The kubelet rotates log files when they exceed a size limit (configurable, default 10 MiB) or after a set number of rotations. When a file is rotated, the inode changes. Fluent Bit's `tail` plugin tracks file position by **inode** and handles rotation transparently — it detects the old inode disappearing and the new file appearing and picks up where it left off.

The SQLite DB (`/var/log/fluentbit-db/flb_kube.db`) persists positions across Fluent Bit pod restarts.

---



## 8. GitOps & ArgoCD for Observability

### Q: How is the observability stack deployed in this project?

**Answer:**
Everything is managed via ArgoCD:

```
k8s/monitoring/prometheus-values.yaml  ← all Prometheus/Grafana/Alertmanager config
        │
argocd/apps/dev/monitoring-app.yaml    ← ArgoCD Application that watches above
        │
ArgoCD syncs → runs:
  helm upgrade kube-prometheus-stack
  with those values
```

Similarly for Fluent Bit:
```
helm-charts-fluent-bit/  +  envs/dev/values-fluent-bit.yaml
        │
argocd/apps/dev/fluent-bit-app.yaml
        │
ArgoCD syncs → deploys Fluent Bit DaemonSet
```

This means every change to Grafana dashboards, alert rules, or Fluent Bit config goes through a Git PR — giving an audit trail, peer review, and rollback capability.

---



## 9. Scenario-Based Questions

### Scenario 1: Logs stopped appearing in Kibana. How do you debug?

**Step-by-step answer:**

```bash
# 1. Check Fluent Bit pods are running
kubectl get pods -n dev -l app=fluent-bit

# 2. Check Fluent Bit logs for errors
kubectl logs -l app=fluent-bit -n dev --tail=50

# 3. Look for Elasticsearch output errors specifically
kubectl logs -l app=fluent-bit -n dev | grep -i "error\|failed\|rejected"

# 4. Check Fluent Bit metrics (if Prometheus is scraping it)
# In Grafana: look at fluentbit_output_errors_total

# 5. Check if the Elastic API key is still valid
# Go to Elastic Cloud console → API Keys → check expiry

# 6. Check if the network path to Elastic Cloud is open
kubectl exec -n dev -it <fluent-bit-pod> -- \
  curl -v https://97f1fa5d7d9d4d58ba3926dfb84ebeb0.us-central1.gcp.cloud.es.io:443

# 7. Check if new indices are being created in Elasticsearch
# Kibana → Dev Tools: GET _cat/indices?v&s=index

# 8. Check if only a specific service's logs are missing (index routing issue)
# or all logs (connectivity/auth issue)
```

Common root causes: expired API key, network policy blocking egress to Elastic Cloud, Fluent Bit OOMKilled (logs too large), wrong namespace filter.

---

### Scenario 2: Prometheus shows a target as DOWN. What do you do?

**Step-by-step answer:**

```bash
# 1. Check Prometheus Targets page
# http://prometheus:9090/targets  → find the red target, read the error message

# 2. Most common error: "connection refused"
# → the /metrics endpoint is not reachable
# Check if the pod is running and the port is correct
kubectl get pod <pod-name> -n dev -o yaml | grep -A5 "ports:"

# 3. Error: "context deadline exceeded"
# → pod is running but /metrics is slow or hanging
# Test directly:
kubectl exec -n dev -it <prometheus-pod> -- \
  curl http://<pod-ip>:<port>/metrics

# 4. Check the ServiceMonitor/PodMonitor labels match
kubectl get servicemonitor -n dev -o yaml | grep -A5 "selector:"
# Ensure they match the pod labels

# 5. Check these flags are set in prometheus-values.yaml:
# serviceMonitorSelectorNilUsesHelmValues: false
# podMonitorSelectorNilUsesHelmValues: false
```

---

### Scenario 3: Grafana dashboard shows "No Data". How do you debug?

**Step-by-step answer:**

1. Check the time range — is it set to "Last 5 minutes" but the metric only exists for the last hour?
2. Check the data source — is it pointing to the correct Prometheus instance?
3. Go to Explore mode → paste the PromQL query → run it manually
4. Check if the metric name exists: `{__name__=~"fluentbit.*"}` to list all Fluent Bit metrics
5. Check if Prometheus is actually scraping the target (Targets page)
6. Check the label selectors in the PromQL — the dashboard may be filtering on a label that doesn't exist in your cluster (e.g. `cluster="prod"` but you're in `dev`)

---

### Scenario 4: You are getting too many alert notifications. What do you change?

**Answer:**
Several levers in Alertmanager:

```yaml
route:
  group_wait: 30s          # increase to 2m to batch more before first notification
  group_interval: 5m       # how long to wait before sending an update to a group
  repeat_interval: 12h     # increase to 24h to halve notification frequency

# Add inhibition rules — suppress lower severity when higher is firing
inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: [alertname, namespace]
```

Also consider:
- Increasing the `for` duration on alert rules to require longer sustained conditions
- Adding more specific `matchers` to route non-actionable alerts to a low-noise receiver
- Using Silences for known flapping alerts during investigation

---

### Scenario 5: A new service is deployed. What do you do to add it to the observability stack?

**Answer:**

**For metrics:**
1. Ensure the Spring Boot service exposes `/metrics` via Micrometer actuator
2. Create a `ServiceMonitor` or `PodMonitor` in the `dev` namespace
3. Commit to `zen-gitops` — ArgoCD syncs it; Prometheus picks it up within 60s
4. Create a Grafana dashboard ConfigMap labelled `grafana_dashboard: "1"` — sidecar loads it live

**For logs:**
- Nothing to do — Fluent Bit collects from all pods in the `dev` namespace automatically
- The Lua filter reads the `app` label and creates a new Elasticsearch index automatically
- Add a Kibana index pattern for the new service: `new-service-*`

---

