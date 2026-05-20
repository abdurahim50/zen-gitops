# Session 3 Agenda — Full GitOps CD: ArgoCD + Helm

**Duration:** 1.5 hours | **Format:** Concept → Code walkthrough → Live demo

---

## Overview

| # | Topic | Type | Time |
|---|---|---|---|
| 1 | Why raw manifests don't scale | Discussion | 10 min |
| 2 | Helm chart anatomy | Concept | 10 min |
| 3 | Migration: raw deployment.yaml → Helm | Live walkthrough | 15 min |
| 4 | Full repo structure tour | Walkthrough | 15 min |
| 5 | Secrets in Helm | Concept + code | 10 min |
| 6 | NGINX Ingress in Helm | Concept + code | 5 min |
| 7 | Live demo: Git push → ArgoCD sync | Demo | 20 min |
| Q&A | — | — | 5 min |

---

## Section 1 (10 min): Why Raw Manifests Don't Scale

### The math

9 services × 4–5 manifest files each = ~42 files for dev alone.
× 3 environments (dev / qa / prod) = **~126 raw YAML files** to maintain.

### What breaks at scale

| Change | Impact with raw manifests |
|---|---|
| Image tag update | Edit 9 `deployment.yaml` files per environment |
| Change readiness probe timeout | Edit 9 files per environment |
| Add a new environment (staging) | Copy and rename ~42 files |
| One env drifts from another | Nobody notices until prod breaks |

### Transition

Helm solves this with **one template + one values file per service per environment**.
25 values files replace ~126 raw manifest files — and all templating is centralized.

---

## Section 2 (10 min): Helm Chart Anatomy

### Directory structure

```
helm-charts/
├── Chart.yaml          ← chart metadata (name, version, appVersion)
├── values.yaml         ← shared defaults — every service inherits these
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    ├── serviceaccount.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    └── _helpers.tpl
```

### Chart.yaml — actual content

```yaml
apiVersion: v2
name: pharma-service
description: Common Helm chart for Pharma microservices
type: application
version: 1.0.0
appVersion: "1.0.0"
keywords:
  - pharma
  - microservice
  - java
  - spring-boot
maintainers:
  - name: Pharma DevOps Team
    email: devops@pharma.com
```

- `name: pharma-service` — one chart shared by all 9 services
- `version: 1.0.0` — chart schema version (bumped when templates change)
- `appVersion: "1.0.0"` — default app version (overridden per service by `image.tag` in values)

### Per-environment values structure

```
envs/
├── dev/   (9 values files)
├── qa/    (8 values files)
└── prod/  (8 values files)
```

**25 values files replace ~126 raw manifest files.**

---

## Section 3 (15 min): Migration: api-gateway deployment.yaml → Helm

### Before: raw manifest (Day 2)

```yaml
# lab2/manifests/api-gateway/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway          # ← hardcoded: must copy-paste for every service
  namespace: dev             # ← hardcoded: must edit for qa/prod
  labels:
    app: api-gateway
    env: dev
spec:
  replicas: 1                # ← hardcoded: no way to differ by environment
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
        env: dev
    spec:
      serviceAccountName: api-gateway
      securityContext:
        fsGroup: 2000
        runAsNonRoot: true
        runAsUser: 1000
      terminationGracePeriodSeconds: 30
      containers:
        - name: pharma-service
          image: 516209541629.dkr.ecr.us-east-1.amazonaws.com/api-gateway:sha-ef1ccc7
          #      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
          #      hardcoded: CI must find-and-replace this string in the file
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: api-gateway
            - secretRef:
                name: db-credentials
            - secretRef:
                name: jwt-secret
          livenessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 60   # ← hardcoded: changing this means editing 9 files
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
            successThreshold: 1
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
            successThreshold: 1
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

### After: Helm template

```yaml
# helm-charts/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "pharma-service.fullname" . }}
  # ^^^ resolves to fullnameOverride from values — same chart works for all 9 services
  labels:
    {{- include "pharma-service.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  # ^^^ driven by values: dev=1, prod=3 — change in one place
  {{- end }}
  selector:
    matchLabels:
      {{- include "pharma-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "pharma-service.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "pharma-service.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          #        ^^^^^^^^^^^^^^^^^^^^^^^^^^    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
          #        ECR repo from values          tag from values — CI writes sha-abc123 here
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          {{- if or .Values.configmap .Values.envFrom }}
          envFrom:
            {{- if .Values.configmap }}
            - configMapRef:
                name: {{ include "pharma-service.fullname" . }}
            {{- end }}
            {{- with .Values.envFrom }}
            {{- toYaml . | nindent 12 }}
            # ^^^ envFrom entries (secretRefs) passed through verbatim from values
            {{- end }}
          {{- end }}
          livenessProbe:
            httpGet:
              path: {{ .Values.livenessProbe.path }}
              port: {{ .Values.livenessProbe.port }}
            initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds }}
            # ^^^ change probe timeout for all 9 services by editing values.yaml once
            periodSeconds: {{ .Values.livenessProbe.periodSeconds }}
            timeoutSeconds: {{ .Values.livenessProbe.timeoutSeconds }}
            failureThreshold: {{ .Values.livenessProbe.failureThreshold }}
            successThreshold: {{ .Values.livenessProbe.successThreshold }}
          readinessProbe:
            httpGet:
              path: {{ .Values.readinessProbe.path }}
              port: {{ .Values.readinessProbe.port }}
            initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.readinessProbe.periodSeconds }}
            timeoutSeconds: {{ .Values.readinessProbe.timeoutSeconds }}
            failureThreshold: {{ .Values.readinessProbe.failureThreshold }}
            successThreshold: {{ .Values.readinessProbe.successThreshold }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- with .Values.volumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

### The values file drives the differences

```yaml
# envs/dev/values-api-gateway.yaml
replicaCount: 1
fullnameOverride: api-gateway
image:
  repository: 516209541629.dkr.ecr.us-east-1.amazonaws.com/api-gateway
  tag: sha-ef1ccc7
  pullPolicy: Always
service:
  type: ClusterIP
  port: 8080
  targetPort: 8080
ingress:
  enabled: true
  className: nginx
  annotations: {}
  host: ""
  path: /api
  pathType: Prefix
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
livenessProbe:
  path: /actuator/health
  port: 8080
  initialDelaySeconds: 60
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1
readinessProbe:
  path: /actuator/health/readiness
  port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1
configmap:
  SPRING_PROFILES_ACTIVE: dev
  LOG_LEVEL: DEBUG
  SERVER_PORT: "8080"
  AUTH_SERVICE_URL: "http://auth-service:8081"
  DRUG_CATALOG_URL: "http://drug-catalog-service:8082"
  NOTIFICATION_URL: "http://notification-service:3000"
  QC_SERVICE_URL: "http://qc-service:8086"
  MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE: "health,info,metrics,prometheus"
envFrom:
  - secretRef:
      name: db-credentials
  - secretRef:
      name: jwt-secret
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::516209541629:role/pharma-dev-eks-role
  name: api-gateway
```

### Preview the rendered output

```bash
helm template api-gateway helm-charts/ -f envs/dev/values-api-gateway.yaml
```

This shows the final YAML ArgoCD will `kubectl apply` — identical to the Day 2 raw manifest, but generated from a single template.

### Payoff table

| Scenario | Raw manifests | Helm |
|---|---|---|
| Update image tag | Edit 9 `deployment.yaml` files per env | Edit 1 values file |
| Change probe timeout | Edit 9 files per env | Edit `values.yaml` default once |
| Add prod environment | Copy ~42 files, rename every field | Copy 9 values files |
| Promote dev image to qa | Edit 9 qa deployment files | Edit 9 qa values files (or CI does it) |

---

## Section 4 (15 min): Full Repo Structure Tour

```
zen-gitops/
├── helm-charts/                     ← ONE chart for all 9 services
│   ├── Chart.yaml
│   ├── values.yaml                  ← shared defaults
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── serviceaccount.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml
│       └── _helpers.tpl
│
├── envs/                            ← per-service per-environment values
│   ├── dev/
│   │   ├── values-api-gateway.yaml
│   │   ├── values-auth-service.yaml
│   │   ├── values-drug-catalog-service.yaml
│   │   └── ... (9 files total)
│   ├── qa/
│   │   └── ... (8 files)
│   └── prod/
│       └── ... (8 files)
│
├── argocd/
│   ├── apps/
│   │   ├── dev/                     ← 9 ArgoCD Application CRDs
│   │   ├── qa/                      ← 8 ArgoCD Application CRDs
│   │   └── prod/                    ← 8 ArgoCD Application CRDs
│   ├── install/                     ← ArgoCD install manifests
│   └── projects/
│       └── pharma-project.yaml      ← AppProject RBAC boundary
│
├── k8s/
│   ├── external-secrets/            ← ESO ExternalSecret CRDs
│   ├── ingress/                     ← NGINX IngressClass + controller
│   ├── namespaces.yaml
│   └── rbac/
│
├── lab1/                            ← Session 1: manual kubectl
└── lab2/                            ← Session 2: ArgoCD + raw manifests
```

### How an ArgoCD Application wires helm-charts + envs together

```yaml
# argocd/apps/dev/api-gateway-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-gateway-dev
  namespace: argocd
  labels:
    env: dev
    app: api-gateway
    managed-by: terraform
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: pharma              # ← scoped to pharma AppProject RBAC boundary

  source:
    repoURL: https://github.com/DPP-2026/zen-gitops.git
    targetRevision: HEAD
    path: helm-charts          # ← render THIS chart
    helm:
      valueFiles:
        - ../envs/dev/values-api-gateway.yaml
        # ^^^ with THIS values file — path is relative to repo root

  destination:
    server: https://kubernetes.default.svc
    namespace: dev             # ← deploy into dev namespace

  syncPolicy:
    automated:
      prune: true              # ← delete K8s resources removed from Git
      selfHeal: true           # ← revert manual kubectl changes automatically
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  revisionHistoryLimit: 10    # ← keep last 10 syncs for rollback
```

### The full CD pipeline

```
Developer pushes code to app repo
        │
        ▼
GitHub Actions CI
  ├── Build Docker image
  ├── Push to ECR: .../api-gateway:sha-abc123
  └── git commit: update envs/dev/values-api-gateway.yaml tag → sha-abc123
        │ git push to zen-gitops
        ▼
zen-gitops repo updated
        │ ArgoCD polls every 3 min (or GitHub webhook)
        ▼
ArgoCD detects api-gateway-dev is OutOfSync
        │ helm template + kubectl apply
        ▼
New pod rolls out in dev namespace with sha-abc123
```

### AppProject — the security boundary

`argocd/projects/pharma-project.yaml` scopes what ArgoCD can touch:
- **sourceRepos**: only `zen-gitops` (not arbitrary repos)
- **destinations**: only `dev`, `qa`, `prod` namespaces on this cluster
- **clusterResourceWhitelist**: controls which cluster-level resources ArgoCD may create

Without AppProject, a misconfigured Application could deploy to any namespace or any cluster ArgoCD has credentials for.

---

## Section 5 (10 min): Secrets in Helm

### What the values file declares

```yaml
# envs/dev/values-api-gateway.yaml (envFrom section)
envFrom:
  - secretRef:
      name: db-credentials
  - secretRef:
      name: jwt-secret
```

The values file names the Secret — it never contains the secret value.

### What the template does with it

```yaml
# helm-charts/templates/deployment.yaml (envFrom block)
{{- if or .Values.configmap .Values.envFrom }}
envFrom:
  {{- if .Values.configmap }}
  - configMapRef:
      name: {{ include "pharma-service.fullname" . }}
  {{- end }}
  {{- with .Values.envFrom }}
  {{- toYaml . | nindent 12 }}
  {{- end }}
{{- end }}
```

Helm passes `envFrom` entries through verbatim. It only knows the Secret **name**, never the secret **value**. The rendered Deployment references `db-credentials` exactly as written in the values file.

### Where the K8s Secret actually comes from — ESO

```
AWS Secrets Manager: /pharma/dev/db-credentials
        │  (value: {"username": "pharmaadmin", "password": "..."})
        │  ESO polls every 1h via IRSA (no static AWS keys)
        ▼
ExternalSecret CRD (k8s/external-secrets/dev-external-secrets.yaml)
        │  creates/refreshes
        ▼
K8s Secret: db-credentials in dev namespace
        │  envFrom: secretRef
        ▼
api-gateway Pod — reads DB_PASSWORD as environment variable
```

### What never happens in this setup

```yaml
# WRONG — never put secret values in values files
env:
  - name: DB_PASSWORD
    value: "supersecret123"   # ← committed to Git permanently
```

Once a secret value is in Git history, it is compromised — even if you delete the file later.

### Verify the chain

```bash
kubectl get externalsecret -n dev
kubectl get secret db-credentials -n dev
kubectl exec -n dev deployment/api-gateway -- env | grep DB_USERNAME
```

---

## Section 6 (5 min): NGINX Ingress in Helm

### Which services expose an ingress

| Service | `ingress.enabled` | Reachable externally at |
|---|---|---|
| api-gateway | `true` | `/api` via NGINX |
| pharma-ui | `true` | `/` via NGINX |
| auth-service | `false` | `http://auth-service.dev.svc.cluster.local:8081` only |
| drug-catalog-service | `false` | internal only |
| notification-service | `false` | internal only |
| qc-service | `false` | internal only |
| (other services) | `false` | internal only |

### Values file ingress section (api-gateway)

```yaml
# envs/dev/values-api-gateway.yaml
ingress:
  enabled: true
  className: nginx
  annotations: {}
  host: ""
  path: /api
  pathType: Prefix
```

### The template conditional

```yaml
# helm-charts/templates/ingress.yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "pharma-service.fullname" . }}
  labels:
    {{- include "pharma-service.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- if .Values.ingress.tls }}
  tls:
    {{- toYaml .Values.ingress.tls | nindent 4 }}
  {{- end }}
  rules:
    - {{- if .Values.ingress.host }}
      host: {{ .Values.ingress.host | quote }}
      {{- end }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: {{ .Values.ingress.pathType }}
            backend:
              service:
                name: {{ include "pharma-service.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

When `ingress.enabled: false`, **no Ingress resource is created at all** — the entire file is skipped. `auth-service` is only reachable at `http://auth-service.dev.svc.cluster.local:8081` from within the cluster.

---

## Section 7 (20 min): Live Demo — Git Push → ArgoCD Sync

### Setup — verify current state

```bash
argocd app list
```

Expected output:

```
NAME                  CLUSTER                         NAMESPACE  PROJECT  STATUS  HEALTH   SYNCPOLICY  ...
api-gateway-dev       https://kubernetes.default.svc  dev        pharma   Synced  Healthy  Auto-Prune  ...
auth-service-dev      https://kubernetes.default.svc  dev        pharma   Synced  Healthy  Auto-Prune  ...
drug-catalog-dev      https://kubernetes.default.svc  dev        pharma   Synced  Healthy  Auto-Prune  ...
notification-dev      https://kubernetes.default.svc  dev        pharma   Synced  Healthy  Auto-Prune  ...
qc-service-dev        https://kubernetes.default.svc  dev        pharma   Synced  Healthy  Auto-Prune  ...
... (all 9 apps Synced/Healthy)
```

### Step 1: Simulate a CI image push — update image tag in Git

Edit `envs/dev/values-api-gateway.yaml`, change:

```yaml
image:
  tag: sha-ef1ccc7   # before
```

to:

```yaml
image:
  tag: sha-demo01    # simulated new CI build
```

Commit and push:

```bash
git add envs/dev/values-api-gateway.yaml
git commit -m "ci: update api-gateway dev image to sha-demo01"
git push
```

### Step 2: Watch ArgoCD detect the change

```bash
argocd app get api-gateway-dev --refresh
argocd app diff api-gateway-dev
```

Expected diff:

```diff
===== apps/Deployment dev/api-gateway ======
  image: 516209541629.dkr.ecr.us-east-1.amazonaws.com/api-gateway:sha-ef1ccc7
+ image: 516209541629.dkr.ecr.us-east-1.amazonaws.com/api-gateway:sha-demo01
```

### Step 3: Auto-sync fires (selfHeal: true)

Within ~3 minutes (or immediately after `--refresh`):

```bash
argocd app wait api-gateway-dev --health --sync
kubectl get pods -n dev -l app=api-gateway
kubectl describe pod -n dev -l app=api-gateway | grep "Image:"
```

The old pod terminates, new pod starts with `sha-demo01`.

### Step 4: Show rollback in the ArgoCD UI

1. Open ArgoCD UI → `api-gateway-dev` → **History & Rollback** tab
2. Two rows appear: previous commit (`sha-ef1ccc7`) and current commit (`sha-demo01`)
3. Click **Rollback** on the previous row → cluster reverts in ~30 seconds
4. Confirm:

```bash
kubectl describe pod -n dev -l app=api-gateway | grep "Image:"
```

**"This is the core GitOps loop. No `kubectl apply`. No `helm upgrade` in CI. Git is the source of truth; ArgoCD is the actuator."**

### What to highlight in the ArgoCD UI during the demo

| UI element | What it shows |
|---|---|
| App tile OutOfSync badge | Detected drift between Git and cluster |
| Diff view | Exactly which fields changed |
| Sync status bar | Rolling update progress |
| History tab | Every Git commit that triggered a sync |
| Self-heal toggle | `selfHeal: true` — manual kubectl changes auto-revert |

---

## Q&A Prep — Likely Questions

| Question | Answer |
|---|---|
| What if the Helm chart template itself changes? | All 9 apps re-render since they all share the same `helm-charts/` path. One template change propagates to every service in every environment. |
| How do we promote an image from dev to qa? | Update `envs/qa/values-<service>.yaml` `image.tag` in Git. CI can automate this after integration tests pass. |
| Can we use different replica counts per env? | Yes — `replicaCount: 1` in dev values, `replicaCount: 3` in prod values. The template reads `{{ .Values.replicaCount }}` from whichever file ArgoCD passes. |
| What happens if ArgoCD is down? | The cluster keeps running. Existing pods are unaffected. When ArgoCD restarts it reconciles from Git and catches up. |
| Why not use `helm upgrade` directly in CI? | Push-based vs pull-based. CI only touches Git, never the cluster. ArgoCD holds the cluster credentials. This means CI compromise does not equal cluster compromise. |
| Why does `helm template` show no namespace in the Deployment? | ArgoCD injects the namespace from `destination.namespace`. Templates should not hardcode namespace — ArgoCD overrides it at apply time. |

---

## Checkpoints

| Checkpoint | Command | Expected |
|---|---|---|
| ArgoCD apps all synced | `argocd app list` | All 9 apps `Synced`/`Healthy` |
| Image tag correct in dev | `kubectl describe pod -n dev -l app=api-gateway \| grep Image:` | `sha-ef1ccc7` |
| Ingress exists for api-gateway | `kubectl get ingress -n dev` | `api-gateway` row present |
| No ingress for auth-service | `kubectl get ingress -n dev` | No `auth-service` row |
| Secrets materialized | `kubectl get secret db-credentials -n dev` | Secret exists |
| ESO synced | `kubectl get externalsecret -n dev` | STATUS: `SecretSynced` |
