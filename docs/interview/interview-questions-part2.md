# Interview Questions & Answers — Part 2

## Table of Contents

| Group | Questions |
|-------|-----------|
| [A — GitOps & ArgoCD](#group-a--gitops--argocd) | A1, A2, A3, A5, A6, A7, A8 |
| [C — External Secrets](#group-c--external-secrets-operator) | C1, C2, C3, C4, C6 |
| [G — Behavioral](#group-g--behavioral--mnc-culture) | G1, G2, G4, G5 |
| [H — Incident Response](#group-h--kubernetes-incident-response) | H1–H9 |
| [I — Troubleshooting Commands](#group-i--kubernetes-troubleshooting-commands) | I1–I7 |

---

# Group A — GitOps & ArgoCD

---

## A1

### Question
> "Walk me through how your GitOps pipeline works end-to-end — from a developer pushing code to it running in production."

### What the interviewer is really testing
- Do you understand the full pipeline or just one slice of it?
- Can you articulate the separation between CI (build) and CD (deploy)?
- Do you know how Git becomes the single source of truth?

---

### Model Answer

Our pipeline has two distinct halves — **CI** (build, test, publish) and **CD** (deploy via GitOps). They are intentionally decoupled.

---

### Full end-to-end flow

```
Developer
    │
    ├─ 1. Writes code, opens PR to application repo (e.g. auth-service)
    │
    ▼
CI Pipeline (GitHub Actions / GitLab CI)
    ├─ 2. Build: docker build → image tagged sha-<commit>
    ├─ 3. Test: unit + integration tests
    ├─ 4. Scan: Trivy image scan, SAST
    ├─ 5. Push: docker push → ECR
    │        873135413040.dkr.ecr.us-east-1.amazonaws.com/auth-service:sha-dbbb634
    │
    └─ 6. Promote: open PR to zen-gitops repo
              Updates: envs/dev/values-auth-service.yaml
              image.tag: sha-dbbb634
    │
    ▼
zen-gitops repo (THIS REPO)
    ├─ 7. PR reviewed, merged to main
    │
    ▼
ArgoCD (watching zen-gitops main branch)
    ├─ 8. Detects change in envs/dev/values-auth-service.yaml
    ├─ 9. Runs: helm template pharma-service + dev values
    ├─ 10. Applies diff to dev namespace in cluster
    ├─ 11. Kubernetes rolls out new Deployment (rolling update)
    │
    ▼
Promotion to QA
    ├─ 12. After dev validation, CI opens PR: promote/qa/auth-service/sha-dbbb634
    │        Updates: envs/qa/values-auth-service.yaml → tag: sha-dbbb634
    ├─ 13. QA team reviews + approves PR
    ├─ 14. Merge triggers ArgoCD sync to qa namespace
    │
    ▼
Promotion to Prod (same pattern)
    ├─ 15. Release manager opens PR: promote/prod/auth-service/sha-dbbb634
    │        Updates: envs/prod/values-auth-service.yaml
    ├─ 16. Senior engineer + release manager approve (2-person rule)
    └─ 17. ArgoCD syncs to prod namespace
```

---

### Architecture Diagram

```
┌──────────────────┐     push image      ┌──────────────────────────────────┐
│  App Repo        │ ──────────────────► │  AWS ECR                         │
│  auth-service    │                     │  :sha-dbbb634                    │
└──────────────────┘                     └──────────────────────────────────┘
        │                                              ▲
        │ CI updates tag                               │ pull image
        ▼                                              │
┌──────────────────┐                     ┌────────────┴─────────────────────┐
│  zen-gitops      │ ◄── ArgoCD polls ── │  ArgoCD                          │
│  (this repo)     │     every 3 min     │                                  │
│                  │                     │  pharma project                  │
│  envs/dev/       │                     │  ├── dev  namespace apps         │
│  envs/qa/        │                     │  ├── qa   namespace apps         │
│  envs/prod/      │                     │  └── prod namespace apps         │
└──────────────────┘                     └──────────────────────────────────┘
                                                       │
                                                       │ kubectl apply
                                                       ▼
                                         ┌─────────────────────────────────┐
                                         │  EKS Cluster                    │
                                         │  ├── dev namespace              │
                                         │  ├── qa  namespace              │
                                         │  └── prod namespace             │
                                         └─────────────────────────────────┘
```

---

### Key GitOps principles to state

1. **Git is the single source of truth** — nobody runs `kubectl apply` manually; everything flows through a PR
2. **CI and CD are separated** — CI touches the app repo; CD is triggered by changes to zen-gitops
3. **Declarative** — the repo describes desired state, not imperative steps
4. **Auditable** — every change to every environment has a PR, a reviewer, a merge commit
5. **Rollback = git revert** — reverting a PR is a rollback, no special tooling needed

---

## A2

### Question
> "How does ArgoCD detect and handle configuration drift? What happens when someone manually changes a resource in the cluster?"

### What the interviewer is really testing
- Understanding of desired state vs live state reconciliation
- How `selfHeal` and `prune` work
- Real-world war story awareness — drift is a common incident cause

---

### Model Answer

**Drift** = the cluster's live state no longer matches what Git says it should be.

---

### How ArgoCD detects drift

ArgoCD runs two continuous processes:

**1. Git polling (every 3 minutes by default)**
```
ArgoCD repo-server → fetches latest commit from zen-gitops
                   → renders Helm templates with env values
                   → produces desired manifests
```

**2. Live state watch (via Kubernetes informers)**
```
ArgoCD application-controller → watches all managed resources via K8s API
                               → caches live state in memory
```

ArgoCD compares desired (from Git) vs live (from cluster) using a **three-way diff**:
- Last applied state (stored in `kubectl.kubernetes.io/last-applied-configuration` annotation)
- Current live state
- Desired state from Git

If they differ, the app status becomes `OutOfSync`.

---

### What happens when someone manually changes a resource

**Scenario:** A developer panics at 3am and runs:
```bash
kubectl set image deployment/auth-service auth-service=...auth-service:hotfix -n prod
```

**With `selfHeal: false` (manual sync — this repo's likely default for prod):**
```
1. ArgoCD detects the image tag mismatch within ~3 minutes
2. App status → OutOfSync
3. ArgoCD UI shows the diff (desired: v1.0.0 vs live: hotfix)
4. Sends notification (if configured)
5. Cluster stays in drifted state until an operator manually syncs
6. The manual change persists until someone acts
```

**With `selfHeal: true` (automatic reconciliation):**
```
1. ArgoCD detects drift within ~3 minutes
2. Immediately reverts: applies the manifest from Git
3. The manual change is OVERWRITTEN
4. App returns to Synced state
5. Developer's hotfix is gone
```

---

### Sync policy options

```yaml
# In ArgoCD Application manifest
spec:
  syncPolicy:
    automated:
      prune: true      # delete resources removed from Git
      selfHeal: true   # revert manual cluster changes
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
```

| Policy | Meaning | Recommended for |
|--------|---------|-----------------|
| `automated` disabled | Manual sync only | prod — human gate required |
| `automated` + `selfHeal: false` | Auto-sync new changes, tolerate manual tweaks | qa |
| `automated` + `selfHeal: true` | Full reconciliation loop | dev |
| `prune: true` | Remove resources deleted from Git | All envs |

---

### Detecting drift proactively

```bash
# Check all apps for drift
argocd app list | grep OutOfSync

# See exactly what drifted
argocd app diff auth-service-prod

# Example output:
# === apps/Deployment/prod/auth-service ===
# -  image: ...auth-service:v1.0.0
# +  image: ...auth-service:hotfix
```

---

### The key insight to give in the interview

> "Drift is not just about image tags. ConfigMaps, resource limits, labels, annotations — anything can drift. In a pharma environment where every prod change needs an audit trail, selfHeal on prod is actually essential compliance tooling: it guarantees the cluster always reflects what's in Git, which is what your change management system approved."

---

## A3

### Question
> "How do you handle multi-environment promotions in GitOps — how does a change go from dev → qa → prod in your setup?"

### What the interviewer is really testing
- Understanding of the promote/* branch pattern (visible in this repo's branches)
- How to enforce environment gates
- Separation of concerns between environments

---

### Model Answer

This repo uses a **promote branch pattern** — visible in the remote branches:
```
remotes/origin/promote/qa/auth-service/sha-c11e73c
remotes/origin/promote/qa/auth-service/sha-d0430b8
remotes/origin/promote/prod/auth-service/sha-a0017b8
remotes/origin/promote/prod/auth-service/latest
```

Each branch name encodes: `promote/<env>/<service>/<image-sha>`

---

### How it works step by step

**Phase 1: Dev deployment (automated)**
```
1. CI builds auth-service image → sha-dbbb634
2. CI script runs:
   git checkout -b promote/dev/auth-service/sha-dbbb634
   # updates envs/dev/values-auth-service.yaml: tag: sha-dbbb634
   git commit -m "promote(dev): auth-service → sha-dbbb634"
   git push origin promote/dev/auth-service/sha-dbbb634
   gh pr create --base main --title "promote(dev): auth-service → sha-dbbb634"
3. PR auto-merges (no approval required for dev)
4. ArgoCD detects main branch change → syncs dev namespace
```

**Phase 2: QA promotion (semi-automated)**
```
5. After dev smoke tests pass (manual or automated E2E):
6. CI or engineer runs promote script:
   git checkout -b promote/qa/auth-service/sha-dbbb634
   # updates envs/qa/values-auth-service.yaml: tag: sha-dbbb634
   git push → PR created
7. QA lead reviews + approves PR
8. Merge → ArgoCD syncs qa namespace
```

**Phase 3: Prod promotion (gated)**
```
9. After QA sign-off:
10. Release manager creates:
    promote/prod/auth-service/sha-dbbb634
11. Requires: 2 approvals (release manager + senior engineer)
12. CODEOWNERS for envs/prod/ enforces this
13. Merge → ArgoCD syncs prod namespace (manual sync policy)
14. Operator watches rollout:
    kubectl rollout status deployment/auth-service -n prod
```

---

### Environment comparison (auth-service actual values)

| Setting | dev | qa | prod |
|---------|-----|----|------|
| Image tag | `sha-dbbb634` | `sha-c11e73c` | `v1.0.0` |
| Spring profile | `dev` | `qa` | `prod` |
| Log level | `DEBUG` | `INFO` | `DEBUG` |
| DB host | `pharma-dev-postgres...` | `<RDS_ENDPOINT>` | `pharma-prod-postgres...` |
| Autoscaling | disabled | enabled (1-3) | disabled |
| fullnameOverride | set | not set | set |
| tmp volume | present | absent | present |

---

### Architecture Diagram

```
            ┌─────────────────────────────────────┐
            │  zen-gitops repo (main branch)       │
            │                                     │
            │  envs/dev/values-auth-service.yaml  │ ← auto-merged
            │  envs/qa/values-auth-service.yaml   │ ← QA approval
            │  envs/prod/values-auth-service.yaml │ ← 2-person approval
            └──────────────┬──────────────────────┘
                           │  ArgoCD watches
              ┌────────────┼────────────┐
              ▼            ▼            ▼
           dev ns        qa ns       prod ns
         (sync: auto)  (sync: auto) (sync: manual)
```

---

### Branch protection rules (what you'd add to GitHub)

```yaml
# .github/CODEOWNERS
envs/prod/   @pharma-release-managers @senior-sre-team
envs/qa/     @pharma-qa-team
envs/dev/    @pharma-developers

# Branch protection on main:
# - require PR review
# - require CODEOWNERS approval
# - require CI to pass
# - prod/* paths require 2 approvals
```

---

## A5

### Question
> "Your ArgoCD project uses `clusterResourceWhitelist: group:* kind:*`. What are the security implications and how would you harden this in a regulated environment like pharma?"

### What the interviewer is really testing
- Security awareness in GitOps
- Understanding of ArgoCD's project-level isolation model
- Pragmatic approach to security hardening in regulated environments

---

### Model Answer

From `argocd/projects/pharma-project.yaml`:
```yaml
clusterResourceWhitelist:
  - group: "*"
    kind: "*"
namespaceResourceWhitelist:
  - group: "*"
    kind: "*"
```

**This means:** Any ArgoCD Application within the `pharma` project can create, modify, or delete **any Kubernetes resource** — including `ClusterRole`, `ClusterRoleBinding`, `PersistentVolume`, `CustomResourceDefinition`, `ValidatingWebhookConfiguration`, and even `Namespace`.

---

### Security implications

| Risk | Scenario |
|------|----------|
| **Privilege escalation** | A compromised app in zen-gitops creates a `ClusterRole` with admin rights and binds it to a new SA |
| **Namespace escape** | An app deploys a `ClusterRoleBinding` that lets it access prod secrets from dev |
| **Persistence** | Attacker adds a `ValidatingWebhookConfiguration` that intercepts all cluster traffic |
| **Data exfiltration** | App creates a `PersistentVolume` mounting sensitive node paths |
| **Supply chain** | A malicious PR to zen-gitops installs a CRD that exfiltrates data |

In pharma, these risks are amplified because:
- Patient data may be in the cluster
- GxP validation requires you to prove no unauthorized changes were made
- A ClusterRole escalation could bypass all the namespace-scoped RBAC controls we built

---

### How to harden it

**Step 1: Restrict cluster-level resources to only what's needed**

```yaml
clusterResourceWhitelist:
  # ArgoCD needs namespaces to manage its apps
  - group: ""
    kind: Namespace
  # External Secrets Operator ClusterSecretStore
  - group: "external-secrets.io"
    kind: ClusterSecretStore
  # Cert-manager ClusterIssuer
  - group: "cert-manager.io"
    kind: ClusterIssuer
  # Prometheus cluster-level rules
  - group: "monitoring.coreos.com"
    kind: ClusterRole
  # Explicitly NO: ClusterRole, ClusterRoleBinding, ValidatingWebhookConfiguration
```

**Step 2: Lock down namespace resources per project**

```yaml
namespaceResourceWhitelist:
  - group: "apps"
    kind: Deployment
  - group: "apps"
    kind: ReplicaSet
  - group: ""
    kind: Service
  - group: ""
    kind: ConfigMap
  - group: ""
    kind: ServiceAccount
  - group: "networking.k8s.io"
    kind: Ingress
  - group: "autoscaling"
    kind: HorizontalPodAutoscaler
  - group: "external-secrets.io"
    kind: ExternalSecret
  - group: "monitoring.coreos.com"
    kind: ServiceMonitor
  # Explicitly excluded: Secret (managed by ESO), Role, RoleBinding
```

**Step 3: Create separate projects per environment with different whitelist**

```yaml
# pharma-prod project — most restrictive
clusterResourceWhitelist: []   # no cluster-level changes in prod
namespaceResourceWhitelist:
  - group: "apps"
    kind: Deployment
  # ... only what prod needs
```

**Step 4: Enable ArgoCD audit logging**
```yaml
# In argocd-cm ConfigMap
data:
  resource.customizations: |
    # log all resource changes
  server.rbac.log.enforce.enable: "true"
```

---

### What to say to close the answer

> "The wildcard is a pragmatic shortcut that works fine when you have full trust in everything that goes into zen-gitops. In a regulated pharma environment that's not enough — you need the platform to enforce least-privilege even if a PR slips through review. I'd start with the namespace whitelist restriction, which stops 90% of the attack surface, and layer in the cluster-level restriction after cataloguing all the CRDs we actually deploy."

---

## A6

### Question
> "How do you do a rollback in GitOps? Walk me through both an ArgoCD UI rollback and a Git-based rollback."

### What the interviewer is really testing
- Practical rollback knowledge — a question always asked at senior/staff level
- Understanding that in GitOps, rollback = changing Git state
- Awareness of the two approaches and when each is appropriate

---

### Model Answer

**There are two rollback mechanisms. They are NOT equivalent.**

---

### Method 1: ArgoCD UI / CLI Rollback (fast, temporary)

This reverts the cluster state to a previous ArgoCD sync revision — **without changing Git**.

```bash
# List history of an application
argocd app history auth-service-prod

# Output:
# ID  DATE                           REVISION
# 3   2026-05-07 10:22:15 +0000 UTC  main (7ad8ac0)  ← current (broken)
# 2   2026-05-06 14:10:03 +0000 UTC  main (4de3cd7)  ← last known good
# 1   2026-05-05 09:15:00 +0000 UTC  main (12c197e)

# Rollback to revision 2
argocd app rollback auth-service-prod 2

# ArgoCD re-applies the manifests from that revision to the cluster
# Status becomes: OutOfSync (because Git still shows newer broken state)
```

**When to use:** Immediate production fire. Gets you stable in 60 seconds.

**Danger:** Git still has the broken commit. If ArgoCD auto-syncs or someone manually syncs, the broken version comes back. You MUST follow up with a Git rollback.

---

### Method 2: Git Revert (permanent, compliant)

This is the correct GitOps rollback — it changes the source of truth.

```bash
# Identify the bad commit
git log --oneline envs/prod/values-auth-service.yaml

# 7ad8ac0 promote(prod): auth-service → sha-a0017b8   ← broke prod
# 4de3cd7 promote(prod): auth-service → sha-c11e73c   ← last good

# Revert the bad commit
git revert 7ad8ac0 --no-edit
# Creates new commit: "Revert promote(prod): auth-service → sha-a0017b8"

# Push and create PR
git push origin revert/prod-auth-service-rollback
gh pr create --base main \
  --title "revert(prod): auth-service rollback" \
  --body "Rolling back sha-a0017b8 due to [incident-link]"

# After PR merges → ArgoCD auto-detects change → syncs prod → rollback complete
```

**When to use:** After the immediate fire is out. This is the permanent fix and the audit trail entry.

---

### Real incident from this repo

Looking at the git log:
```
7ad8ac0 Merge pull request #64 - Revert "promote(prod): auth-service → sha-a0017b8"
6132a31 Revert "promote(prod): auth-service → sha-a0017b8"
1e9e1a2 Merge pull request #63 - promote(prod): auth-service → sha-a0017b8
4de3cd7 promote(prod): auth-service → sha-a0017b8
```

This repo has a real rollback in its history — PR #63 deployed `sha-a0017b8` to prod, then PR #64 reverted it. This is the Git-based rollback pattern in action.

---

### Decision flowchart

```
Production incident — need rollback
           │
           ├─ Is prod actively broken RIGHT NOW?
           │      YES → argocd app rollback <app> <last-good-revision>
           │             (cluster stable in 60s)
           │             THEN → follow up with git revert
           │
           └─ Can wait 10-15 min for PR process?
                  YES → git revert → PR → merge
                         (ArgoCD syncs automatically)
                         (preferred — creates audit trail)
```

---

### Key point to make in interview

> "In GitOps, the ArgoCD rollback is an emergency brake — it buys you time. The Git revert is the actual rollback — it's what your change management audit will reference. In a pharma environment under GxP, you want the Git revert to be the primary record: who approved rolling back, what was reverted, and why."

---

## A7

### Question
> "How would you implement a blue-green or canary deployment strategy using ArgoCD?"

### What the interviewer is really testing
- Knowledge of Argo Rollouts (the natural companion to ArgoCD)
- Understanding of traffic splitting mechanisms (weighted services, ingress annotations)
- Knowing when to use blue-green vs canary

---

### Model Answer

Standard ArgoCD + Helm only supports **rolling updates** (replace pods incrementally). For blue-green or canary, you need **Argo Rollouts**.

---

### Blue-Green Deployment

Two full environments run simultaneously; traffic switches atomically.

```yaml
# Replace Deployment with Rollout
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: auth-service
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: auth-service
  template:
    # ... same pod spec as Deployment
  strategy:
    blueGreen:
      activeService: auth-service-active      # receives 100% traffic
      previewService: auth-service-preview    # new version goes here first
      autoPromotionEnabled: false             # require manual promotion
      scaleDownDelaySeconds: 30              # keep old version for 30s after switch
```

```yaml
# Two services required
---
apiVersion: v1
kind: Service
metadata:
  name: auth-service-active    # Nginx ingress points here
spec:
  selector:
    app: auth-service
    # Argo Rollouts adds: rollouts-pod-template-hash: <blue-hash>
---
apiVersion: v1
kind: Service
metadata:
  name: auth-service-preview   # QA tests against this
spec:
  selector:
    app: auth-service
    # Argo Rollouts adds: rollouts-pod-template-hash: <green-hash>
```

**Promotion flow:**
```bash
# New image deployed to preview (green)
# Run smoke tests against auth-service-preview
# Promote: switch all traffic to green
kubectl argo rollouts promote auth-service -n prod

# If bad, abort: switch back to blue instantly
kubectl argo rollouts abort auth-service -n prod
```

---

### Canary Deployment

Gradually shift traffic to new version, monitor, then proceed or rollback.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: catalog-service
  namespace: prod
spec:
  strategy:
    canary:
      canaryService: catalog-service-canary
      stableService: catalog-service-stable
      trafficRouting:
        nginx:
          stableIngress: catalog-service-ingress
      steps:
        - setWeight: 10         # send 10% to canary
        - pause: {duration: 5m} # watch for 5 min
        - setWeight: 30         # increase to 30%
        - pause: {duration: 10m}
        - analysis:             # automated gate: check error rate
            templates:
              - templateName: error-rate-check
        - setWeight: 100        # full rollout
```

```yaml
# AnalysisTemplate — automated quality gate using Prometheus
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: error-rate-check
spec:
  metrics:
    - name: error-rate
      interval: 1m
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-operated.monitoring.svc:9090
          query: |
            sum(rate(http_server_requests_seconds_count{
              app="catalog-service", status=~"5.."
            }[5m])) /
            sum(rate(http_server_requests_seconds_count{
              app="catalog-service"
            }[5m])) < 0.01
```

---

### Blue-Green vs Canary — when to use which

| Scenario | Strategy | Why |
|----------|----------|-----|
| auth-service (critical, fast failover needed) | Blue-Green | Instant rollback, zero traffic on bad version |
| catalog-service (high traffic, gradual risk) | Canary | Limit blast radius to 10% of users |
| pharma-ui (user-facing, A/B testing) | Canary | Test UX changes with subset of users |
| DB schema changes | Blue-Green | Need old version running during migration |

---

## A8

### Question
> "You have a hotfix that must go to prod immediately but the normal PR process takes hours. How do you handle this in GitOps without breaking the process?"

### What the interviewer is really testing
- Maturity in handling the GitOps vs urgency tension
- Whether you have a documented break-glass procedure
- Do you know when to bypass vs when to hold firm

---

### Model Answer

**First principle: the GitOps process exists for good reasons. A break-glass procedure is not an excuse to bypass it permanently — it is a documented, audited exception.**

---

### The break-glass procedure

**Step 1: Declare an incident formally**
```
Incident declared: P1 - auth-service prod returning 500s
Incident commander: [name]
Communication channel: #incident-prod-auth
Time: 2026-05-07 02:14 UTC
```

**Step 2: Choose the fastest safe option**

Option A — ArgoCD rollback (if the current version is broken):
```bash
# Fastest: 60 seconds. No Git change needed.
argocd app rollback auth-service-prod <last-good-revision>
# This is not bypassing GitOps — it's using ArgoCD's built-in rollback
```

Option B — Emergency direct push (true break-glass, new fix needed):
```bash
# Create a branch directly from prod state
git checkout -b hotfix/prod-auth-service-null-ptr main

# Make minimal fix to envs/prod/values-auth-service.yaml
# (e.g., pointing to a pre-built hotfix image)

# Push and create PR with emergency label
gh pr create --base main \
  --title "hotfix(prod): auth-service null pointer in token validation" \
  --label "emergency,break-glass" \
  --body "P1 incident #123. Approved by: @cto @release-manager"
```

**Step 3: Emergency approval**
- Minimum 1 senior approver (relaxed from normal 2)
- Verbal approval logged in incident channel
- PR merged immediately

**Step 4: ArgoCD syncs prod** (if manual sync policy, trigger manually)
```bash
argocd app sync auth-service-prod --force
kubectl rollout status deployment/auth-service -n prod
```

**Step 5: Post-incident (within 24h)**
- Write postmortem
- Create a follow-up PR with proper testing if the hotfix was rushed
- Update runbook if the break-glass procedure needs adjustment

---

### What guardrails you keep even in break-glass

| Guardrail | Keep? | Reason |
|-----------|-------|--------|
| All changes go through Git | ✅ YES | Audit trail is non-negotiable in pharma |
| PR required (no direct push to main) | ✅ YES | One approver minimum |
| CI must pass | ⚠️ OPTIONAL | May skip if emergency image already tested |
| 2-person approval rule | ⚠️ RELAXED | 1 senior approver acceptable, documented |
| Manual prod sync | ✅ YES | Human confirms before ArgoCD applies |

---

### Key line for the interview

> "In GitOps, there's no such thing as bypassing the process — there's only making the process faster. The break-glass procedure is a documented, auditable fast lane, not an exit from the guardrails. The difference between a mature and an immature GitOps setup is whether that fast lane is designed in advance or improvised under pressure at 2am."

---

# Group C — External Secrets Operator

---

## C2

### Question
> "Walk me through how a secret flows from AWS Secrets Manager into a running pod in this setup — step by step."

### What the interviewer is really testing
- Can you trace the full data flow through multiple Kubernetes abstractions?
- Do you understand IRSA at a mechanism level?
- Can you explain CRDs operationally?

---

### Model Answer

The flow has **5 distinct layers**. Most engineers can explain 2-3; knowing all 5 is what gets you the role.

---

### Full step-by-step flow

**Step 1: IRSA authentication — how ESO talks to AWS**

```
ESO controller pod (in kube-system)
    │
    ├── Has ServiceAccount: external-secrets (namespace: kube-system)
    ├── SA has annotation: eks.amazonaws.com/role-arn: arn:aws:iam::873135413040:role/external-secrets-role
    │
    ├── K8s injects projected ServiceAccount token into ESO pod
    │   (via: automountServiceAccountToken)
    │
    └── When ESO calls AWS:
        1. ESO presents SA JWT token to AWS STS
        2. AWS validates JWT signature against cluster's OIDC issuer
           (registered at: oidc.eks.us-east-1.amazonaws.com/id/<cluster-id>)
        3. AWS issues temporary credentials (AccessKeyId, SecretAccessKey, SessionToken)
        4. ESO uses these to call secretsmanager:GetSecretValue
        (no static AWS credentials stored anywhere)
```

**Step 2: ClusterSecretStore defines the connection**

From `k8s/external-secrets/cluster-secret-store.yaml`:
```yaml
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: kube-system
```
This is the cluster-wide "connector" to AWS Secrets Manager.

**Step 3: ExternalSecret defines what to fetch**

From `k8s/external-secrets/prod-external-secrets.yaml`:
```yaml
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-credentials      # ← name of K8s Secret to create
    creationPolicy: Owner     # ESO owns this Secret's lifecycle
  data:
    - secretKey: DB_USERNAME  # ← key name in K8s Secret
      remoteRef:
        key: /pharma/prod/db-credentials   # ← path in AWS Secrets Manager
        property: username                 # ← field within the JSON secret
```

**Step 4: ESO reconciler creates the Kubernetes Secret**

```
ESO controller loop (runs every refreshInterval):
1. Read ExternalSecret CR
2. Call AWS: GetSecretValue(SecretId: /pharma/prod/db-credentials)
3. AWS returns JSON: {"username": "pharma_user", "password": "s3cr3t"}
4. Extract .username → "pharma_user", .password → "s3cr3t"
5. Create/Update Kubernetes Secret:
   kubectl create secret generic db-credentials \
     --from-literal=DB_USERNAME=pharma_user \
     --from-literal=DB_PASSWORD=s3cr3t \
     -n prod
6. Sets ownerReference on Secret pointing to ExternalSecret
   (if ExternalSecret is deleted, Secret is deleted too — creationPolicy: Owner)
```

**Step 5: Pod consumes the Secret**

From `envs/prod/values-auth-service.yaml`:
```yaml
envFrom:
  - secretRef:
      name: db-credentials   # ← the Secret ESO created
  - secretRef:
      name: jwt-secret
```

Kubernetes injects all keys from `db-credentials` Secret as environment variables into every container in the pod:
```
DB_USERNAME=pharma_user
DB_PASSWORD=s3cr3t
```

---

### Full Architecture Diagram

```
AWS Secrets Manager
  /pharma/prod/db-credentials → {"username": "pharma_user", "password": "s3cr3t"}
  /pharma/prod/jwt-secret     → {"secret": "hs512-key-..."}
         ▲
         │ GetSecretValue (IRSA temp creds)
         │
ESO Controller (kube-system)
  ├── reads ClusterSecretStore
  ├── reads ExternalSecret CRs
  └── writes K8s Secrets (every 1h)
         │
         │ creates/updates
         ▼
K8s Secrets (prod namespace)
  ├── db-credentials: {DB_USERNAME, DB_PASSWORD}
  └── jwt-secret: {JWT_SECRET}
         │
         │ envFrom: secretRef
         ▼
auth-service pod
  └── env: DB_USERNAME, DB_PASSWORD, JWT_SECRET
```

---

## C3

### Question
> "What is IRSA (IAM Roles for Service Accounts) and why is the ClusterSecretStore using JWT auth instead of static credentials?"

### What the interviewer is really testing
- Deep AWS + Kubernetes security knowledge
- Understanding of OIDC federation
- Why static credentials are dangerous and how IRSA eliminates them

---

### Model Answer

**IRSA = IAM Roles for Service Accounts** — a mechanism that allows Kubernetes pods to assume AWS IAM roles without storing any AWS credentials in the cluster.

---

### The problem IRSA solves

**Old approach (static credentials — never do this):**
```yaml
# DANGEROUS — static credentials in a Secret
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
data:
  AWS_ACCESS_KEY_ID: AKIAIOSFODNN7EXAMPLE
  AWS_SECRET_ACCESS_KEY: <base64-encoded-key>
```
Problems:
- Key is long-lived — if leaked, attacker has permanent access
- Rotation is manual and painful
- Key has no scope — can't restrict to a specific namespace or pod
- Violates least-privilege — all pods using the SA get the same key

---

### How IRSA works (mechanism)

**Setup (one-time, done via Terraform in this repo):**
```
1. EKS cluster has an OIDC issuer URL:
   https://oidc.eks.us-east-1.amazonaws.com/id/<cluster-id>

2. AWS IAM trusts this OIDC issuer:
   Trust policy on external-secrets-role:
   {
     "Condition": {
       "StringEquals": {
         "oidc.eks.us-east-1.amazonaws.com/id/<id>:sub":
           "system:serviceaccount:kube-system:external-secrets"
       }
     }
   }
   This means: "only the 'external-secrets' SA in 'kube-system' can assume this role"

3. SA is annotated:
   eks.amazonaws.com/role-arn: arn:aws:iam::873135413040:role/external-secrets-role
```

**At runtime (every API call):**
```
ESO pod starts
    │
    ├── K8s injects projected ServiceAccount token (JWT, 1h TTL) into pod
    │   at: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    │
    └── When ESO calls AWS Secrets Manager:
        1. AWS SDK calls STS AssumeRoleWithWebIdentity(
             RoleArn: arn:aws:iam::873135413040:role/external-secrets-role,
             WebIdentityToken: <SA JWT>
           )
        2. AWS STS validates JWT signature against OIDC issuer public keys
        3. Checks trust policy conditions (namespace + SA name match)
        4. Returns temporary credentials (15min to 1h TTL)
        5. ESO uses temp creds for Secrets Manager API call
```

---

### Why this is better than static credentials

| Property | Static Credentials | IRSA |
|----------|-------------------|------|
| Credential lifetime | Permanent (until manually rotated) | 15 minutes to 1 hour |
| Scope | Attached to key, not to identity | Bound to specific namespace + SA name |
| Storage | In a K8s Secret (exploitable) | Never stored — generated on demand |
| Rotation | Manual, high-risk | Automatic — tokens auto-rotate |
| Audit trail | AWS CloudTrail shows access key ID | CloudTrail shows role + cluster + SA identity |
| Blast radius if leaked | Full AWS account access | Only the ESO role permissions, for max 1h |

---

### From the ClusterSecretStore in this repo

```yaml
auth:
  jwt:
    serviceAccountRef:
      name: external-secrets
      namespace: kube-system
```

This tells ESO: "use the JWT from the `external-secrets` ServiceAccount in `kube-system` to authenticate." This is the IRSA mechanism — the JWT is the web identity token in the `AssumeRoleWithWebIdentity` call.

---

# Group G — Behavioral / MNC Culture

---

## G1

### Question
> "Tell me about a time you had to convince a team to adopt GitOps when they were comfortable with traditional CI/CD pipelines. What was the resistance and how did you handle it?"

### What the interviewer is really testing
- Change management and influence skills
- Whether you can articulate GitOps value in business terms
- Empathy for the people being asked to change

---

### Model Answer (STAR format)

**Situation:**
Our team had been running Jenkins pipelines with direct `kubectl apply` to all three environments — dev, qa, and prod. The pipeline worked but we had three recurring problems: occasional prod deployments that nobody could trace back to a PR, configuration drift (someone had manually patched a configmap in prod months ago and nobody knew), and a compliance audit finding that we lacked an approval gate for production changes.

**Task:**
I was asked to propose a solution for the compliance finding. I saw it as an opportunity to move to GitOps, but I knew the team would push back — they'd spent months building and tuning those Jenkins pipelines.

**Action:**

*First, I understood the resistance before proposing anything.* I ran a team retro specifically asking "what's painful about our current deployment process?" — not "should we change it?" That gave me real pain points in their words:
- "I can never tell what's actually running in prod without sshing into the cluster"
- "Jenkins went down last week and we couldn't deploy for 3 hours"
- "I'm nervous every time I have to do a prod deployment"

*Then I proposed GitOps as the solution to THEIR problems, not as a technology migration.* I reframed it:
- "Can always tell what's in prod" → Git is the single source of truth, `git log` shows the exact state
- "Jenkins outage blocks deployments" → ArgoCD is inside the cluster, not a dependency
- "Nervous about prod" → PRs require approval, and you can preview the diff before applying

*I ran a 2-week pilot on one service (auth-service in dev only).* I set up ArgoCD, migrated one values file, and showed the team the UI. The visual diff of what would change before syncing was the moment it clicked for most people.

*I kept the Jenkins pipelines running in parallel for 4 weeks.* I didn't ask anyone to trust something unproven. Side by side for a month, then we decommissioned Jenkins for CD.

**Result:**
Full migration completed over 6 weeks. The compliance finding was resolved — we now had PR-based approval gates for prod changes with full audit trail. The team's biggest surprise was how much faster rollbacks became: from "find the Jenkins build, re-trigger it" to "git revert, merge, done in 5 minutes."

---

### What interviewers at top MNCs listen for

- Did you acknowledge that the existing solution had VALUE? (Respect for what people built)
- Did you run a pilot before asking for full commitment?
- Did you solve their problems, not impose your preferences?
- Were there measurable outcomes?

---

## G2

### Question
> "Describe a production incident you handled in a Kubernetes-based system. What was the impact, what was your role, and what did you explain afterward?"

### What the interviewer is really testing
- Structured incident response under pressure
- Ownership and blameless postmortem culture
- Learning mindset — what changed after?

---

### Model Answer (STAR format)

**Situation:**
At 11:40pm on a Tuesday, our auth-service in prod started returning 401 for all requests. 100% of users were being logged out and couldn't log back in. Our PagerDuty alert fired on the 5% error rate threshold — it should have fired earlier but the alert window was 5 minutes which meant 5 minutes of impact before we even knew.

**Task:**
I was the on-call SRE. I had 15 minutes to diagnose and either roll back or fix it, because the business had a hard SLA with the client.

**Action:**

*T+0 (acknowledge):* Checked ArgoCD first — was there a recent deployment? Yes: catalog-service had been deployed 8 minutes ago.

*T+2 (narrow the blast radius):* Auth-service itself was not redeployed — why was it broken? Checked the auth-service pods: all 3 were Running and passing liveness. No CrashLoopBackOff, no OOMKilled.

*T+4 (read logs):*
```bash
kubectl logs -n prod deployment/auth-service --since=15m | grep ERROR
```
Found: `JWT secret key not found: jwt-secret key JWT_SECRET is empty`

*T+5 (check the secret):*
```bash
kubectl get secret jwt-secret -n prod -o jsonpath='{.data.JWT_SECRET}' | base64 -d
# output: (empty)
```
The secret existed but was empty. Checked the ExternalSecret:
```bash
kubectl describe externalsecret jwt-secret -n prod
```
Status showed: `SecretSyncedError: AccessDenied: User: arn:aws:sts::873135413040:assumed-role/external-secrets-role is not authorized to perform: secretsmanager:GetSecretValue`

*T+6 (root cause):* The catalog-service deployment had included a Terraform change that accidentally modified the `external-secrets-role` IAM policy. The policy change removed the `secretsmanager:GetSecretValue` permission for `/pharma/prod/jwt-secret` path.

*T+8 (fix):* I had the Terraform change reverted (git revert, terraform apply — 4 minutes). Then forced ESO re-sync:
```bash
kubectl annotate externalsecret jwt-secret -n prod force-sync=$(date +%s) --overwrite
```
*T+12:* JWT secret repopulated. Rolling restart of auth-service:
```bash
kubectl rollout restart deployment/auth-service -n prod
```
*T+15:* Auth-service serving 200s. Incident resolved.

**Result and what changed:**

Postmortem within 24h. Three action items:
1. **Added ESO health alert** — `kubectl get externalsecret -A` returning non-Ready should page immediately. We would have caught this before user impact.
2. **Separated IAM policy management** from application Terraform** — the infra that auth-service depends on should not be modifiable by the catalog-service Terraform module.
3. **Added integration test** in CI that validates the ESO sync works before marking a deployment successful.

---

### What to emphasize in the interview

- You had a structured diagnostic process — not guessing, checking one layer at a time
- You didn't just fix it, you asked "why did this take 15 minutes to find?"
- The postmortem was blameless — the Terraform change was a system design problem, not a person's fault
- Three concrete action items, not vague "we'll be more careful"

---

## G4

### Question
> "A new engineer joins and accidentally deploys to prod by pushing directly to the main branch. How do you prevent this from happening again? Walk me through the guardrails you'd put in place."

### What the interviewer is really testing
- Systems thinking — fix the system, not blame the person
- Layered defense: don't rely on a single guardrail
- Knowledge of GitHub/GitLab branch protection, CODEOWNERS, ArgoCD RBAC

---

### Model Answer

**First principle: this is a system failure, not a human failure.** The system allowed it to happen. A new engineer should not be able to accidentally deploy to prod — that's a design problem in the guardrails, not a training problem.

**Defense in depth — 5 layers:**

---

**Layer 1: Git branch protection (prevent the push)**
```yaml
# GitHub repository settings → Branch protection rules for 'main'
main branch rules:
  ✅ Require a pull request before merging
  ✅ Require approvals: 1 (general), 2 (for envs/prod/** changes)
  ✅ Require review from Code Owners
  ✅ Dismiss stale pull request approvals when new commits are pushed
  ✅ Restrict who can push to main: [release-managers, senior-sre]
  ✅ Do not allow bypassing the above settings (even for admins)
```

**Layer 2: CODEOWNERS (enforce approval by right people)**
```bash
# .github/CODEOWNERS
# envs/prod/ changes require prod team sign-off
/envs/prod/          @pharma-release-managers @senior-sre-team
/argocd/             @pharma-platform-team
/k8s/rbac/           @pharma-security-team

# This means: even if a PR has 2 approvals,
# if it touches envs/prod/ it ALSO needs a @pharma-release-managers approval
```

**Layer 3: ArgoCD RBAC (prevent sync even if the commit gets through)**
```yaml
# argocd-rbac-cm ConfigMap
data:
  policy.csv: |
    # Developers can only sync dev and qa
    p, role:developer, applications, sync, pharma/*, deny
    p, role:developer, applications, sync, pharma/*-dev, allow
    p, role:developer, applications, sync, pharma/*-qa, allow

    # Only release-managers can sync prod
    p, role:release-manager, applications, sync, pharma/*-prod, allow

    # Assign roles
    g, pharma-developers, role:developer
    g, pharma-release-managers, role:release-manager
```

**Layer 4: ArgoCD sync policy (require manual approval for prod)**
```yaml
# prod ArgoCD Applications: no automated sync
spec:
  syncPolicy: {}   # no automated field = manual sync only
  # An operator must explicitly click "Sync" in ArgoCD UI or run:
  # argocd app sync auth-service-prod
  # This is a second human gate after the PR merge
```

**Layer 5: Path-based CI checks (validate intent)**
```yaml
# .github/workflows/protect-prod.yaml
on:
  pull_request:
    paths:
      - 'envs/prod/**'
jobs:
  require-prod-label:
    runs-on: ubuntu-latest
    steps:
      - name: Check for production-deployment label
        run: |
          LABELS=$(gh pr view ${{ github.event.pull_request.number }} --json labels -q '.labels[].name')
          if ! echo "$LABELS" | grep -q "production-deployment"; then
            echo "ERROR: PRs touching envs/prod/ require the 'production-deployment' label"
            exit 1
          fi
```

---

### After the incident: the conversation with the engineer

> "This was a gap in our setup — the guardrails should not have allowed this. We're fixing the system so this can't happen again regardless of experience level. Let's make sure you understand the promotion process now, but the system change is the real fix."

---

### Summary of layers

```
Engineer pushes commit
         │
Layer 1: Branch protection → blocks direct push to main ✋
         │ (bypassed if push access granted)
Layer 2: CODEOWNERS → prod changes need release-manager approval ✋
         │ (bypassed if CODEOWNERS not enforced)
Layer 3: ArgoCD RBAC → developer can't trigger prod sync ✋
         │ (bypassed if someone with access manually syncs)
Layer 4: Manual sync policy → human must explicitly approve prod sync ✋
         │ (bypassed if operator doesn't check what they're syncing)
Layer 5: CI gate → PR without label fails checks ✋

5 independent layers. An accident requires bypassing ALL of them.
```

---

## G5

### Question
> "You have 3 environments but different teams own dev and prod. How do you structure Git branch protection, ArgoCD project permissions, and Helm values so neither team can accidentally affect the other?"

### What the interviewer is really testing
- Org-scale GitOps design
- How technical controls enforce team boundaries
- Understanding of ArgoCD multi-tenancy

---

### Model Answer

**The design principle:** ownership boundaries must be enforced by the platform, not by convention. "Please don't touch prod" is not a guardrail.

---

### Git Structure

```
zen-gitops/
├── envs/
│   ├── dev/        ← owned by dev-team
│   ├── qa/         ← owned by qa-team (shared gatekeeper)
│   └── prod/       ← owned by prod-team (release managers)
├── helm-charts/    ← owned by platform-team
└── argocd/         ← owned by platform-team
```

```bash
# .github/CODEOWNERS
/envs/dev/           @pharma-dev-team
/envs/qa/            @pharma-qa-team
/envs/prod/          @pharma-release-managers
/helm-charts/        @pharma-platform-team
/argocd/             @pharma-platform-team
/k8s/                @pharma-platform-team
```

Branch protection on `main`:
- Any PR touching `envs/prod/**` requires `@pharma-release-managers` approval — even if it was opened by a senior dev
- Any PR touching `helm-charts/**` requires `@pharma-platform-team` approval — prevents dev-team from modifying shared chart

---

### ArgoCD Project Structure (per team)

```yaml
# pharma-dev project — for dev team
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: pharma-dev
spec:
  destinations:
    - server: https://kubernetes.default.svc
      namespace: dev            # dev team can ONLY deploy to dev namespace
  sourceRepos:
    - "https://github.com/ravdy/zen-gitops.git"
  roles:
    - name: dev-deployer
      policies:
        - p, proj:pharma-dev:dev-deployer, applications, *, pharma-dev/*, allow
      groups:
        - pharma-dev-team

---
# pharma-prod project — for release managers
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: pharma-prod
spec:
  destinations:
    - server: https://kubernetes.default.svc
      namespace: prod           # prod project can ONLY deploy to prod namespace
  roles:
    - name: prod-deployer
      policies:
        - p, proj:pharma-prod:prod-deployer, applications, sync, pharma-prod/*, allow
      groups:
        - pharma-release-managers
```

With this setup:
- Dev team members cannot see or sync prod ArgoCD Applications
- Release managers cannot see dev internal Applications
- Both teams can see qa (shared project)

---

### Kubernetes RBAC alignment

```
                Git CODEOWNERS         ArgoCD RBAC          K8s Namespace RBAC
                ───────────────        ─────────────        ──────────────────
dev-team   →    envs/dev/**            pharma-dev project   pharma-deployer (dev ns)
qa-team    →    envs/qa/**             pharma-qa project    pharma-deployer (qa ns)
prod-team  →    envs/prod/**           pharma-prod project  pharma-deployer (prod ns)
platform   →    helm-charts/,argocd/   all projects (admin) cluster-admin (argocd SA)
```

Three independent enforcement layers — an accident requires bypassing all three.

---

### The key architectural insight

> "The critical mistake I've seen is teams using a single ArgoCD project for all environments. That means a dev team member with ArgoCD access can accidentally sync prod. Separate projects per environment, with separate role bindings, is how you enforce team ownership at the platform level rather than relying on discipline."

> Cloud architecture and DR Q&A: [DevOps_Interview_Full_2026.md](./DevOps_Interview_Full_2026.md) (BS1, BS2).

---

# Group H — Kubernetes Incident Response

---

## H1

### Question
> "A pod in the prod namespace is stuck in `CrashLoopBackOff`. Walk me through your exact debugging steps — what commands do you run and in what order?"

### What the interviewer is really testing
- Systematic debugging vs guessing
- Exact kubectl command knowledge
- Ability to interpret common error patterns

---

### Model Answer

**CrashLoopBackOff means:** the container started, ran briefly, crashed, and Kubernetes keeps restarting it with exponential backoff (10s → 20s → 40s → 80s → 5min cap).

---

### Step-by-step with exact commands

**Step 1: Get the pod name and quick overview**
```bash
kubectl get pods -n prod
# NAME                           READY   STATUS             RESTARTS   AGE
# auth-service-7d9f8c-xk2pv      0/1     CrashLoopBackOff   5          8m
```

**Step 2: Describe the pod — read Events section first**
```bash
kubectl describe pod auth-service-7d9f8c-xk2pv -n prod
# Focus on:
# - Image: 873135413040.dkr.ecr.us-east-1.amazonaws.com/auth-service:sha-xxx
# - Last State: Terminated / Exit Code
# - Events: OOMKilled? ImagePullBackOff? Liveness failed?
```

Common exit codes:
| Exit Code | Meaning |
|-----------|---------|
| 0 | Clean exit (unexpected for a server) |
| 1 | Application error (check logs) |
| 137 | OOMKilled (memory limit exceeded) |
| 139 | Segfault |
| 143 | SIGTERM — graceful shutdown not completing |

**Step 3: Read the logs from the CRASHED container (--previous flag)**
```bash
# Logs from the container that just crashed (not the new one starting)
kubectl logs auth-service-7d9f8c-xk2pv -n prod --previous

# Common findings:
# - "Cannot create bean... DataSource" → DB not reachable
# - "Caused by: java.lang.OutOfMemoryError" → OOM before K8s kills it
# - "Failed to load secret: jwt-secret key not found" → Missing secret
# - "Port 8081 already in use" → Port conflict (rare in containers)
```

**Step 4: Read the logs of the currently running (starting) container**
```bash
kubectl logs auth-service-7d9f8c-xk2pv -n prod
# See if current startup attempt shows the same error
# If it's in the backoff window, it may not have started yet
```

**Step 5: Check env vars and mounted secrets**
```bash
# Only possible during the brief window when pod is Running before crash
# Or exec into an identical pod in dev
kubectl exec -n prod auth-service-7d9f8c-xk2pv -- printenv | grep -E "DB_|JWT_|SPRING_"

# Check if secrets exist and have values
kubectl get secret db-credentials -n prod -o jsonpath='{.data}' | jq
kubectl get secret jwt-secret -n prod -o jsonpath='{.data.JWT_SECRET}' | base64 -d
```

**Step 6: Check recent events at namespace level**
```bash
kubectl get events -n prod --sort-by='.lastTimestamp' | tail -20
# Look for: FailedScheduling, BackOff, OOMKilling, FailedMount
```

**Step 7: Check resource usage just before crash**
```bash
kubectl top pod -n prod
# If you're too late, check Prometheus:
# container_memory_working_set_bytes{pod="auth-service-..."}
```

---

### Decision tree by exit code

```
CrashLoopBackOff
       │
       ├── Exit Code 137 (OOMKilled)
       │       → kubectl describe pod: look for "OOMKilled" in Last State
       │       → Fix: increase memory limit in values-auth-service.yaml
       │         or set JVM heap: -Xmx400m (lower than 512Mi limit)
       │
       ├── Exit Code 1 (App crash)
       │       → kubectl logs --previous: look for Java exception
       │       │
       │       ├── DB connection refused → check DB host, network policy, RDS status
       │       ├── Secret not found → check ESO sync status
       │       └── Port already in use → check SERVICE_PORT vs server.port config
       │
       ├── Exit Code 0 (Clean exit)
       │       → Application is exiting immediately (treating crash as success)
       │       → Check if entrypoint is wrong or app has no daemon process
       │
       └── ImagePullBackOff (different status)
               → check image tag, ECR permissions, imagePullSecrets
```

---

## H2

### Question
> "The auth-service pod is in `Pending` state for 10 minutes after a deployment. What are all the possible causes and how do you isolate each one?"

### What the interviewer is really testing
- Comprehensive Kubernetes scheduling knowledge
- Systematic narrowing from many possibilities
- `kubectl describe pod` reading skills

---

### Model Answer

**Pending means:** the pod exists but the Kubernetes scheduler has not assigned it to a node yet (or a node assignment failed).

---

### All possible causes

**Step 1: Always start with `kubectl describe pod`**
```bash
kubectl describe pod auth-service-<hash> -n prod
# The Events section at the bottom tells you EXACTLY why it's pending
# If Events is empty — the scheduler hasn't even tried yet
```

---

### Cause 1: Insufficient resources (most common)

```
Events:
  Warning  FailedScheduling  10m  default-scheduler  
    0/3 nodes are available: 3 Insufficient cpu, 3 Insufficient memory.
```

```bash
# Check node capacity vs current usage
kubectl top nodes
kubectl describe nodes | grep -A5 "Allocated resources"

# Check what the pod is requesting
kubectl describe pod auth-service-<hash> -n prod | grep -A5 "Requests:"
# Requests: cpu: 100m, memory: 256Mi (from values-auth-service.yaml)

# Fix: scale up the node group (ASG) or reduce requests
```

---

### Cause 2: ResourceQuota exceeded (namespace-level limit)

```bash
kubectl describe resourcequota -n prod
# If quota is set and the new pod exceeds it → Pending

# Check if a quota is blocking
kubectl get resourcequota -n prod
kubectl describe resourcequota -n prod
```

---

### Cause 3: PersistentVolumeClaim not bound

From auth-service values — it has a `tmp` emptyDir, not a PVC. But if it were:
```
Events:
  Warning  FailedScheduling  pod has unbound immediate PersistentVolumeClaims
```

```bash
kubectl get pvc -n prod
# STATUS should be Bound; if Pending → storage class provisioner issue
kubectl describe pvc <pvc-name> -n prod
```

---

### Cause 4: Node selector / affinity not matching

```bash
kubectl describe pod auth-service-<hash> -n prod | grep -A3 "Node-Selectors"
# If nodeSelector is set and no node matches:
# "0/3 nodes are available: 3 node(s) didn't match node selector"

# Check node labels
kubectl get nodes --show-labels
```

---

### Cause 5: Taints and tolerations

```bash
# Check if nodes have taints that the pod doesn't tolerate
kubectl describe nodes | grep -A3 "Taints:"
kubectl describe pod auth-service-<hash> -n prod | grep -A3 "Tolerations:"
```

Common example: a node tainted `node.kubernetes.io/not-ready:NoSchedule` means the node itself has a problem.

---

### Cause 6: Image pull issue (pod goes Pending then ImagePullBackOff)

```bash
kubectl describe pod auth-service-<hash> -n prod
# Events: Failed to pull image "873135413040.dkr.ecr.us-east-1.amazonaws.com/auth-service:sha-xxx"
# Check: does imagePullSecrets exist? Is ECR auth working?
kubectl get secret -n prod | grep ecr
```

---

### Cause 7: Topology spread constraints too strict

From `helm-charts/values.yaml`, `topologySpreadConstraints: []` by default. But if set:
```bash
# If maxSkew: 1 and only 2 zones available with 3 pods → can't schedule
# "0/3 nodes are available: 3 node(s) didn't match pod topology spread constraints"
kubectl describe pod auth-service-<hash> -n prod | grep -A5 "TopologySpreadConstraints"
```

---

### Quick isolation flowchart

```
Pod Pending for >2 min
       │
       └── kubectl describe pod → check Events
               │
               ├── "Insufficient cpu/memory" → check node capacity, resize requests
               ├── "unbound PVC" → check storage class, PVC status
               ├── "didn't match node selector" → check node labels
               ├── "didn't match taint" → check node taints + pod tolerations
               ├── "didn't match topology spread" → relax maxSkew or add nodes
               ├── "quota exceeded" → check ResourceQuota
               └── "no events at all" → scheduler overwhelmed, check kube-scheduler logs
```

---


## H5

### Question
> "A new deployment of auth-service succeeded (all pods running) but `/actuator/health/readiness` keeps returning 503. Traffic is not routing to the new pods. Debug this."

### What the interviewer is really testing
- Understanding of Kubernetes readiness probe + service endpoint mechanics
- Knowing that readiness failure = removed from Service endpoints
- Systematic multi-layer debugging

---

### Model Answer

**Key mechanics:** When a pod's readiness probe fails, Kubernetes removes it from the Service's Endpoints object. The nginx ingress → Service → no endpoints → 503 or traffic only going to old pods.

---

### Step-by-step

**Step 1: Confirm readiness probe is failing**
```bash
kubectl describe pod auth-service-<hash> -n prod | grep -A10 "Readiness:"
# Readiness:  http-get http://:8081/actuator/health/readiness
# Failure threshold: 3 times in a row → pod not ready

kubectl get pods -n prod
# READY column shows 0/1 for affected pods
```

**Step 2: Manually hit the readiness endpoint to see the actual response**
```bash
kubectl exec -n prod auth-service-<hash> -- \
  curl -v http://localhost:8081/actuator/health/readiness

# Possible responses:
# 200 {"status":"UP"} → probe passing now but wasn't before? Timing issue
# 200 {"status":"DOWN"} → app is reporting itself down
# 503 {"status":"OUT_OF_SERVICE"} → Spring component is not ready
# Connection refused → app not listening on 8081
# Timeout → app started but is stuck
```

**Step 3: Read the full health response to see which component is DOWN**
```bash
kubectl exec -n prod auth-service-<hash> -- \
  curl -s http://localhost:8081/actuator/health | python3 -m json.tool

# Example:
# {
#   "status": "DOWN",
#   "components": {
#     "db": {
#       "status": "DOWN",
#       "details": {
#         "error": "Unable to acquire JDBC Connection: Timeout after 30000ms"
#       }
#     },
#     "diskSpace": { "status": "UP" }
#   }
# }
```

**Step 4: Check if the Service has endpoints**
```bash
kubectl get endpoints auth-service -n prod
# NAME           ENDPOINTS         AGE
# auth-service   <none>            5m   ← no endpoints! All pods failing readiness

# Once pods pass readiness:
# auth-service   10.0.1.45:8081    5m
```

---

### Common root causes for readiness 503

| Cause | Symptom in `/actuator/health` | Fix |
|-------|------------------------------|-----|
| DB not reachable | `"db": {"status": "DOWN"}` | Check DB_HOST config, RDS security group, network policy |
| DB credential wrong after rotation | `"db": {"status": "DOWN", "error": "Auth failed"}` | Check ESO sync, restart pods after secret update |
| Missing secret (env var empty) | App fails to start DataSource bean | Check ESO sync status |
| Port mismatch | Connection refused | Verify SERVICE_PORT env var matches values file |
| Slow JVM startup (within initialDelaySeconds) | Probe fires too early | Increase `readinessProbe.initialDelaySeconds` in values file |
| App deployed with wrong Spring profile | Different config loaded | Check SPRING_PROFILES_ACTIVE env var |

---

### Specific to this repo — check configmap values

```bash
kubectl get configmap auth-service -n prod -o yaml
# Verify:
# DB_HOST: pharma-prod-postgres.cs3c424yurej.us-east-1.rds.amazonaws.com (correct)
# SERVER_PORT: "8081" (matches readiness probe port)
# SPRING_PROFILES_ACTIVE: prod
```

---


## H7

### Question
> "You get an OOMKilled event on the manufacturing-service. The pod restarts every 30 minutes. How do you investigate root cause and what is your immediate vs permanent fix?"

### What the interviewer is really testing
- OOM debugging methodology
- JVM-specific memory knowledge (for Spring Boot services)
- Distinguishing memory leak from under-provisioning

---

### Model Answer

OOMKilled = Linux kernel OOM killer terminated the process because it exceeded the container's memory limit (currently `512Mi` in this repo).

---

### Step 1: Confirm OOMKilled

```bash
kubectl describe pod manufacturing-service-<hash> -n prod
# Last State:     Terminated
#   Reason:       OOMKilled
#   Exit Code:    137
#   Started:      Thu, 07 May 2026 02:00:00 +0000
#   Finished:     Thu, 07 May 2026 02:28:00 +0000
```

---

### Step 2: Get the memory usage trend BEFORE the kill

```bash
# In Prometheus/Grafana:
container_memory_working_set_bytes{
  pod=~"manufacturing-service-.*",
  namespace="prod",
  container="pharma-service"
}
```

Two distinct patterns tell you different stories:

```
Pattern A — Memory leak:
  MB
 512 │                      ██ ← killed
     │                  ████
     │            ██████
     │        ████
 256 │   █████
     └─────────────────────── time
     (gradual linear increase over 30 min → memory leak)

Pattern B — Under-provisioning:
  MB
 512 │ ██ ← killed immediately on startup
     │
     └─────────────────────── time
     (instant spike → JVM heap set too high for limit)
```

---

### Step 3: Check JVM heap configuration

For Spring Boot services, the JVM needs explicit heap sizing:

```bash
kubectl exec -n prod deployment/manufacturing-service -- \
  java -XX:+PrintFlagsFinal -version 2>&1 | grep -i "heapsize\|xmx"

# Common problem:
# JVM defaults to 25% of container memory as max heap = 128Mi (512Mi * 0.25)
# But JVM also uses metaspace, thread stacks, native memory
# Total JVM memory = heap + metaspace + threads + etc. can easily exceed 512Mi
```

**Fix for JVM memory management:**
```yaml
# In configmap of manufacturing-service values:
configmap:
  JAVA_OPTS: "-Xms256m -Xmx384m -XX:MaxMetaspaceSize=96m -XX:+UseContainerSupport"
  # Xmx384m + MaxMetaspace96m + overhead ≈ 480m < 512Mi limit
```

Or use `XX:+UseContainerSupport` (Java 11+) which automatically respects container limits:
```yaml
JAVA_OPTS: "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
# 75% of 512Mi = 384Mi for heap → safer
```

---

### Step 4: Investigate memory leak (if Pattern A)

```bash
# Get heap dump before next OOM kill
kubectl exec -n prod deployment/manufacturing-service -- \
  jcmd 1 GC.heap_info

kubectl exec -n prod deployment/manufacturing-service -- \
  jcmd 1 VM.native_memory summary

# For full heap dump (warning: large file):
kubectl exec -n prod deployment/manufacturing-service -- \
  jmap -dump:format=b,file=/tmp/heap.hprof 1
kubectl cp prod/manufacturing-service-<pod>:/tmp/heap.hprof ./heap.hprof
# Analyze with Eclipse MAT or VisualVM
```

Common Spring Boot memory leak causes:
- `@Cacheable` with no eviction policy and unbounded keys
- Database ResultSet not closed (connection leak → memory accumulates)
- Static collections growing indefinitely
- Hibernate L2 cache misconfiguration

---

### Immediate vs Permanent fix

| Timeframe | Action |
|-----------|--------|
| **Immediate** | Increase memory limit to `768Mi` or `1Gi` (buys time for investigation) |
| **Immediate** | Set explicit `-Xmx` flag to prevent JVM from consuming all available memory |
| **Short-term** | Enable GC logging to see if GC is running frequently before OOM |
| **Permanent** | Find and fix the leak: heap dump analysis, add `spring.cache.caffeine.spec=maximumSize=1000,expireAfterWrite=10m` |
| **Permanent** | Add Prometheus alert: memory usage > 80% of limit for 5 minutes → page before OOM |

---


## H9

### Question
> "Nginx ingress is returning 502 Bad Gateway for the pharma-ui. The pods are running and healthy. Walk through every layer you'd check."

### What the interviewer is really testing
- Full network path knowledge: external → ingress → service → pod
- Nginx-specific knowledge (502 vs 503 vs 504 meanings)
- Reading ingress configuration

---

### Model Answer

**502 Bad Gateway means:** nginx received a bad/invalid response from the upstream (backend pod). It reached the pod but got something unexpected.

Compare: 503 = no upstream available, 504 = upstream timed out.

---

### Layer-by-layer investigation

**Layer 1: Verify pods are actually running AND ready**
```bash
kubectl get pods -n prod -l app.kubernetes.io/name=pharma-ui
# READY must be 1/1, not 0/1
# If 0/1 → readiness probe failing → see H5

kubectl get endpoints pharma-ui -n prod
# If <none> → all pods failing readiness → service has no backends → 503 not 502
# If endpoints exist → pods are ready, but nginx is getting bad response
```

**Layer 2: Check if nginx can reach the pod directly**
```bash
# Get pod IP
POD_IP=$(kubectl get pod -n prod -l app.kubernetes.io/name=pharma-ui \
  -o jsonpath='{.items[0].status.podIP}')

# Exec into nginx pod and try the backend directly
kubectl exec -n ingress-nginx deployment/ingress-nginx-controller -- \
  curl -v http://${POD_IP}:8080/
# If this returns 200 → nginx routing config is wrong
# If this returns something unexpected → app is returning bad response
```

**Layer 3: Check ingress configuration**
```bash
kubectl describe ingress pharma-ui -n prod
# Check:
# - Backend service name and port match actual Service
# - ingressClassName: nginx (matches the nginx controller)
# - Path: correct?

kubectl get ingress pharma-ui -n prod -o yaml
```

From this repo's pattern (`envs/prod/values-pharma-ui.yaml`):
```yaml
ingress:
  enabled: true
  className: nginx
  host: prod.pharma.internal
  path: /
  pathType: Prefix
```

**Layer 4: Check the Service**
```bash
kubectl describe service pharma-ui -n prod
# Selector must match pod labels
# Port must match targetPort

kubectl get service pharma-ui -n prod -o yaml
# spec.ports[].targetPort should match the port pharma-ui listens on
```

Common mistake: `service.port: 8080` but `service.targetPort: 3000` (UI is on 3000) — nginx reaches the pod but nothing is listening on 3000.

**Layer 5: Check nginx logs**
```bash
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --since=5m | \
  grep -i "pharma-ui\|502\|bad gateway"

# Common nginx upstream error messages:
# "connect() failed (111: Connection refused)"  → wrong port
# "upstream sent invalid header"               → app not speaking HTTP
# "recv() failed (104: Connection reset by peer)" → app crashed mid-response
```

**Layer 6: Check TLS / SSL passthrough**

From this repo's ArgoCD ingress pattern:
```yaml
annotations:
  nginx.ingress.kubernetes.io/ssl-passthrough: "true"
```

If pharma-ui has ssl-passthrough set but the pod is not serving HTTPS, nginx gets garbage back → 502.

```bash
kubectl get ingress pharma-ui -n prod -o yaml | grep -A5 annotations
# If ssl-passthrough: "true" → pod must serve HTTPS
# If not set → nginx handles TLS, pod serves plain HTTP
```

**Layer 7: Check if it's a protocol mismatch (HTTP/2 vs HTTP/1.1)**
```bash
# If pharma-ui is gRPC or HTTP/2 but nginx defaults to HTTP/1.1:
# Add annotation:
# nginx.ingress.kubernetes.io/backend-protocol: "GRPC"  or "HTTP2"
kubectl describe ingress pharma-ui -n prod | grep backend-protocol
```

---

### 502 investigation summary

```
502 Bad Gateway
       │
       ├── Pods not ready? (0/1) → readiness probe issue (see H5)
       │
       ├── No endpoints? → all pods failing readiness
       │
       ├── Nginx can't reach pod? → network policy blocking ingress → pod
       │
       ├── Wrong port in Service? → connection refused
       │
       ├── SSL mismatch? → ssl-passthrough on non-HTTPS backend
       │
       └── App crashing mid-response? → check pod logs during the 502
```

---

# Group I — Kubernetes Troubleshooting Commands

---

## I1

### Question
> "What is the exact sequence of `kubectl` commands you run when a pod is not starting? Give me the actual commands."

### What the interviewer is really testing
- Command fluency — do you hesitate or go straight to the right command?
- Systematic approach vs jumping to conclusions

---

### The exact sequence

```bash
# 1. Get the pod name and see the status at a glance
kubectl get pods -n prod
# Look at: STATUS (Pending/CrashLoopBackOff/OOMKilled/ImagePullBackOff/Terminating)
# Look at: RESTARTS (high number = CrashLoop)
# Look at: READY (0/1 = not ready)

# 2. Get the full picture — Events section is the most important part
kubectl describe pod <pod-name> -n prod
# Scroll to bottom: Events section tells you exactly what happened
# Also check: Limits/Requests, node assigned, volumes mounted

# 3. Read the logs of the crashed container (MUST use --previous for CrashLoop)
kubectl logs <pod-name> -n prod --previous
# --previous = logs from the container that just exited, not the new one starting

# 4. Read the logs of the currently starting container (if available)
kubectl logs <pod-name> -n prod
# May be empty if still in backoff window

# 5. Check namespace-level events sorted by time
kubectl get events -n prod --sort-by='.lastTimestamp' | tail -20
# Catches: scheduling failures, OOM events, image pull failures

# 6. If Pending, check node availability
kubectl top nodes
kubectl describe nodes | grep -E "MemoryPressure|DiskPressure|PIDPressure"

# 7. Check if the relevant secrets/configmaps exist
kubectl get secret db-credentials -n prod
kubectl get configmap auth-service -n prod

# 8. For CrashLoopBackOff — exec in during the brief running window
# (or use a debug pod with same image)
kubectl debug pod/<pod-name> -n prod \
  --image=busybox \
  --copy-to=debug-pod \
  -- sh
```

---

### The 30-second cheatsheet

```bash
# Quick status
kubectl get pods -n prod -o wide

# What happened
kubectl describe pod <name> -n prod | grep -A20 Events

# Why it crashed
kubectl logs <name> -n prod --previous 2>&1 | tail -30

# Namespace-level events
kubectl get events -n prod --sort-by='.lastTimestamp' | tail -10
```

---

## I2

### Question
> "How do you check if an ExternalSecret has successfully synced from AWS Secrets Manager? What does a failed sync look like?"

---

### Commands

```bash
# 1. Quick status of all ExternalSecrets in a namespace
kubectl get externalsecret -n prod
# NAME             STORE                REFRESH INTERVAL   STATUS          READY
# db-credentials   aws-secrets-manager  1h                 SecretSynced    True   ← good
# jwt-secret       aws-secrets-manager  1h                 SecretSyncedError False ← problem

# 2. Full status with conditions and last sync time
kubectl describe externalsecret db-credentials -n prod
# Look for:
# Status:
#   Refresh Time: 2026-05-07T09:45:00Z   ← when last synced
#   Conditions:
#     Type: Ready
#     Status: True
#     Reason: SecretSynced
#     Message: Secret was synced

# 3. Verify the resulting K8s Secret was created and has values
kubectl get secret db-credentials -n prod
kubectl get secret db-credentials -n prod -o jsonpath='{.data}' | jq 'keys'
# Should show: ["DB_PASSWORD","DB_USERNAME"]

# Check values are non-empty (decode base64)
kubectl get secret db-credentials -n prod \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d && echo

# 4. Check ESO controller logs for errors
kubectl logs -n kube-system deployment/external-secrets --since=1h | \
  grep -i "error\|db-credentials\|failed"
```

---

### What a failed sync looks like

```yaml
# kubectl describe externalsecret db-credentials -n prod

Status:
  Conditions:
  - Last Transition Time: "2026-05-07T09:00:00Z"
    Message: 'could not get secret value: AccessDenied: User: arn:aws:sts::873135413040:assumed-role/external-secrets-role/...
      is not authorized to perform: secretsmanager:GetSecretValue on resource: arn:aws:secretsmanager:us-east-1:873135413040:secret:/pharma/prod/db-credentials*'
    Reason:      SecretSyncedError
    Status:      "False"
    Type:        Ready
```

---

## I3

### Question
> "A node is NotReady. How do you safely drain and cordon it without dropping traffic from running pods?"

---

### Exact procedure

```bash
# 1. Confirm the node is NotReady
kubectl get nodes
# NAME                STATUS     ROLES    AGE
# ip-10-0-1-45.ec2    NotReady   <none>   5d

# 2. Understand WHY before touching it
kubectl describe node ip-10-0-1-45.ec2
# Look for:
# - Conditions: MemoryPressure/DiskPressure/NetworkUnavailable = True
# - Events: kubelet stopped posting status

# 3. CORDON first — prevents NEW pods from being scheduled here
# (existing pods keep running, just no new scheduling)
kubectl cordon ip-10-0-1-45.ec2
# Node ip-10-0-1-45.ec2 cordoned
# Node STATUS becomes: NotReady,SchedulingDisabled

# 4. Check what pods are running on this node
kubectl get pods --all-namespaces \
  --field-selector spec.nodeName=ip-10-0-1-45.ec2

# 5. Check PodDisruptionBudgets before draining
# If a PDB says minAvailable: 1 and there's only 1 pod, drain will BLOCK
kubectl get pdb --all-namespaces

# 6. DRAIN — evicts all pods with grace period
kubectl drain ip-10-0-1-45.ec2 \
  --ignore-daemonsets \          # DaemonSet pods can't be moved — ignore them
  --delete-emptydir-data \       # pods using emptyDir lose their data — accept this
  --grace-period=60 \            # give pods 60s to finish in-flight requests
  --timeout=300s                 # drain must complete within 5 min or fail

# 7. Verify no more non-daemonset pods on the node
kubectl get pods --all-namespaces \
  --field-selector spec.nodeName=ip-10-0-1-45.ec2 | grep -v daemonset

# 8. Now safe to: reboot the node, replace it, investigate the issue

# 9. If node recovers: uncordon to allow scheduling again
kubectl uncordon ip-10-0-1-45.ec2
```

---

### Why cordon before drain?

Cordon prevents new pods from landing on the node. Drain evicts existing pods. Without cordoning first, evicted pods could immediately reschedule onto the same bad node before the drain command removes them.

---

## I4

### Question
> "How do you exec into a running container in the prod namespace if `kubectl exec` is blocked by RBAC? How do you debug network issues from inside a pod without installing tools?"

---

### If kubectl exec is blocked

From this repo's prod RBAC — `pods/exec` is NOT in the prod role. So developers cannot exec into prod pods. Options:

**Option 1: Ephemeral debug container (Kubernetes 1.25+, no RBAC exec needed)**
```bash
# Attach a debug container to a running pod without exec
kubectl debug -it <pod-name> -n prod \
  --image=busybox:latest \
  --target=pharma-service   # share PID/net/etc. namespaces with main container

# This creates a temporary container in the pod's namespace
# You can inspect processes, network, filesystem from here
```

**Option 2: Debug copy of the pod**
```bash
# Create a copy of the pod with a debug shell, without replacing it
kubectl debug <pod-name> -n prod \
  --copy-to=debug-auth-service \
  --image=eclipse-temurin:21-jre \
  -it -- bash
# Delete when done
kubectl delete pod debug-auth-service -n prod
```

---

### Debug network without installing tools (busybox is pre-installed)

```bash
# From inside a running pod (if exec allowed) or ephemeral container:

# 1. Check DNS resolution
cat /etc/resolv.conf
nslookup pharma-prod-postgres.cs3c424yurej.us-east-1.rds.amazonaws.com

# 2. Check if a port is reachable (nc / wget in busybox)
nc -zv pharma-prod-postgres.cs3c424yurej.us-east-1.rds.amazonaws.com 5432
# Connected → DB port open
# refused → network policy or security group blocking

# 3. Check HTTP connectivity (wget in busybox, curl if available)
wget -q -O- http://catalog-service:8080/actuator/health

# 4. Check env vars (no tools needed)
env | grep DB_

# 5. Check filesystem (read-only root issue)
ls -la /tmp
touch /tmp/test && echo "tmp is writable" || echo "tmp is read-only"

# 6. From Java process perspective (if JDK tools available)
jcmd 1 VM.system_properties | grep -i "db\|datasource"
```

---


## I6

### Question
> "A Helm upgrade failed halfway through and left the release in a broken state. Walk me through diagnosing and recovering it."

---

### Diagnosis

```bash
# 1. Check release status
helm list -n prod
# NAME            NAMESPACE  REVISION  STATUS          CHART
# auth-service    prod       5         failed          pharma-service-1.0.0

helm status auth-service -n prod
# STATUS: failed
# LAST DEPLOYED: Thu May 07 02:15:00 2026
# NOTES: ...

# 2. See the full history
helm history auth-service -n prod
# REVISION  UPDATED     STATUS      CHART                    DESCRIPTION
# 1         ...         superseded  pharma-service-1.0.0    Install complete
# 2         ...         superseded  pharma-service-1.0.0    Upgrade complete
# 3         ...         superseded  pharma-service-1.0.0    Upgrade complete
# 4         ...         superseded  pharma-service-1.0.0    Upgrade complete
# 5         ...         failed      pharma-service-1.0.0    Upgrade failed: ...

# 3. See what changed in the failed revision
helm get manifest auth-service -n prod --revision 5 > /tmp/failed.yaml
helm get manifest auth-service -n prod --revision 4 > /tmp/previous.yaml
diff /tmp/previous.yaml /tmp/failed.yaml

# 4. Check the actual K8s resources for inconsistency
kubectl get deployments,services,configmaps -n prod -l app.kubernetes.io/instance=auth-service
```

---

### Recovery options

**Option A: Rollback to last good revision (most common)**
```bash
helm rollback auth-service 4 -n prod
# Rolls back to revision 4

# Verify
helm status auth-service -n prod
# STATUS: deployed
```

**Option B: Force upgrade with --cleanup-on-fail (if rollback not working)**
```bash
helm upgrade auth-service ./helm-charts \
  -n prod \
  -f envs/prod/values-auth-service.yaml \
  --cleanup-on-fail \    # delete new resources if upgrade fails
  --atomic               # rollback automatically if upgrade fails
```

**Option C: Nuclear option — uninstall and reinstall**
```bash
# ONLY if rollback is not working
# WARNING: brief downtime

helm uninstall auth-service -n prod
# Wait for resources to clean up
kubectl get pods -n prod | grep auth-service

helm install auth-service ./helm-charts \
  -n prod \
  -f envs/prod/values-auth-service.yaml
```

---

### Why do Helm upgrades fail halfway?

Common causes in this repo's setup:
1. **Job hook failed** — if a pre-upgrade hook (e.g., DB migration) fails, upgrade is marked failed but some resources were already updated
2. **Readiness timeout** — new pod never becomes ready within `--timeout` (default 5min); Helm marks as failed but deployment exists
3. **Immutable field change** — tried to change a field like `selector.matchLabels` which can't be updated; the Deployment object is stuck
4. **Resource conflict** — a resource already exists that Helm didn't create (not in its release history)

For the immutable field case:
```bash
kubectl delete deployment auth-service -n prod
helm upgrade auth-service ./helm-charts -n prod -f envs/prod/values-auth-service.yaml
```

---

## I7

### Question
> "How do you verify that the correct container image SHA is running in prod and it matches what ArgoCD deployed? Give exact commands."

---

### Commands

```bash
# 1. What ArgoCD thinks should be deployed
argocd app get auth-service-prod
# Look for: Summary → Images: 873135413040.dkr.ecr.us-east-1.amazonaws.com/auth-service:v1.0.0

# 2. What the Deployment spec says (desired state)
kubectl get deployment auth-service -n prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# 873135413040.dkr.ecr.us-east-1.amazonaws.com/auth-service:v1.0.0

# 3. What is ACTUALLY running in the pod (imageID contains the SHA256 digest)
kubectl get pods -n prod -l app.kubernetes.io/name=auth-service \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
# auth-service-7d9f8c-xk2pv   docker-pullable://...auth-service@sha256:abc123def456...

# 4. Cross-check the SHA against ECR (what was actually pushed)
aws ecr describe-images \
  --repository-name auth-service \
  --region us-east-1 \
  --query 'imageDetails[?contains(imageTags,`v1.0.0`)].[imageTags,imageDigest]' \
  --output table
# Expected: sha256:abc123def456... (should match imageID from step 3)

# 5. Compare Git tag to image digest (full chain verification)
# What commit is tagged v1.0.0?
git log --oneline -1 v1.0.0   # if tag exists in app repo

# What SHA is in the prod values file?
cat envs/prod/values-auth-service.yaml | grep tag
# tag: v1.0.0

# 6. One-liner to print all running images in prod
kubectl get pods -n prod \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.containerStatuses[*]}  {.name}: {.imageID}{"\n"}{end}{end}'
```

---

### Why imageID matters more than image tag

Docker tags are **mutable**. Someone can push a new image to ECR with the same tag `v1.0.0`, overwriting the previous one. The `imageID` contains the immutable SHA256 content hash of the image — it changes if even one byte of the image changes. Verifying `imageID` is the only way to be certain what code is running.

In a pharma GxP environment, the `imageID` SHA is what you record in your audit trail — not the tag.
