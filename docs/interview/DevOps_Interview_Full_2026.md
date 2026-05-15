# DevOps Interview Guide — Zen Pharma Platform (2026)

Interview questions and model answers for the Zen Pharma GitOps platform. Answers reference the repos: `zen-gitops`, `zen-infra`, `zen-pharma-backend`, `zen-pharma-frontend`.

## Table of Contents

| Group | Questions |
|-------|-----------|
| [Behavioral & Situational](#group--behavioral--situational) | BS1, BS2 |

> Additional technical Q&A: see [interview-questions-part2.md](./interview-questions-part2.md) (GitOps, External Secrets, incidents, kubectl).

---

# Group — Behavioral & Situational

---

## BS1

### Question
> "Explain the cloud architecture for the Zen Pharma application — from the user request to the database. Walk me through each layer and why you designed it that way."

### What the interviewer is really testing
- Can you explain a real system end-to-end, not just one tool?
- Do you understand separation of concerns (network, compute, data, secrets, delivery)?
- Can you justify trade-offs (single cluster vs multi-cluster, GitOps, IRSA)?

---

### Model Answer

Zen Pharma is a **microservices platform** for pharmaceutical operations: authentication, drug catalog, inventory, manufacturing, QC, suppliers, notifications, and a React UI. The cloud stack is **AWS-centric** with **Kubernetes as the runtime** and **GitOps for delivery**.

---

### High-level architecture (north–south flow)

```
Internet / corporate VPN
         │
         ▼
┌────────────────────────────────────────────────────────────┐
│  AWS (us-east-1)                                           │
│                                                            │
│  Route 53 / internal DNS  →  prod.pharma.internal          │
│         │                                                  │
│         ▼                                                  │
│  NGINX Ingress Controller (in EKS)                         │
│         │  TLS termination, path routing                   │
│         ▼                                                  │
│  api-gateway (ClusterIP)  ──►  backend microservices       │
│         │                      (auth, catalog, inventory,  │
│         │                       manufacturing, qc, etc.)   │
│         ▼                                                  │
│  pharma-ui (React, ClusterIP)                              │
│         │                                                  │
│         ├──────────────────►  AWS RDS PostgreSQL           │
│         │                      (per-env instances/schemas) │
│         │                                                  │
│         └──────────────────►  AWS Secrets Manager          │
│                                via External Secrets (IRSA) │
└────────────────────────────────────────────────────────────┘
```

**Companion repos (split by concern):**

| Repo | Responsibility |
|------|----------------|
| `zen-infra` | Terraform — VPC, EKS, RDS, ECR, IAM, OIDC for IRSA |
| `zen-pharma-backend` | Spring Boot microservices (build + CI) |
| `zen-pharma-frontend` | React UI |
| `zen-gitops` | Desired cluster state — Helm values, ArgoCD apps, RBAC, ESO |

---

### Layer-by-layer breakdown

**1. Edge and ingress**
- Users hit **NGINX Ingress** inside the cluster (`ingress-nginx`), not individual pod IPs.
- Host-based routing (e.g. `prod.pharma.internal`) sends `/` to **pharma-ui** and API paths to **api-gateway**.
- Ingress gives a **stable entry point** while pods are ephemeral.

**2. Application tier (EKS)**
- **One EKS cluster**, **three namespaces**: `dev`, `qa`, `prod` — logical isolation, shared control plane cost.
- **Nine workloads**: api-gateway, auth-service, catalog-service, inventory-service, manufacturing-service, qc-service, supplier-service, notification-service, pharma-ui.
- Each service is a **Deployment + Service + ConfigMap** (from shared Helm chart `helm-charts/`).
- **api-gateway** routes to internal services via Kubernetes DNS (`http://auth-service:8081`, etc.).
- **prod** runs **2+ replicas**, **HPA** (2–5), and **pod anti-affinity** so pods spread across nodes/AZs.

**3. Data tier**
- **PostgreSQL on RDS** — one RDS endpoint per environment (e.g. `pharma-prod-postgres....rds.amazonaws.com`).
- Schemas separated in DB (`pharmacy`, `inventory`, `procurement`, `manufacturing` — see `db-init/01-schemas.sql`).
- Services connect via **ConfigMap** (`DB_HOST`) + **Secret** (`DB_USERNAME`, `DB_PASSWORD` from ESO).
- RDS is in **private subnets**; only the cluster security group can reach port 5432.

**4. Secrets and identity**
- **No secrets in Git.** Credentials live in **AWS Secrets Manager** (`/pharma/<env>/db-credentials`, `jwt-secret`, etc.).
- **External Secrets Operator** syncs them into Kubernetes Secrets every hour.
- **IRSA** — ESO's ServiceAccount assumes `external-secrets-role` via OIDC; no long-lived AWS keys in the cluster.
- Per-service **ServiceAccounts** where apps need AWS API access (annotated with `eks.amazonaws.com/role-arn`).

**5. Container images and registry**
- CI builds images → pushes to **ECR** (`873135413040.dkr.ecr.us-east-1.amazonaws.com/<service>:<tag>`).
- EKS nodes pull via IAM/node role or `imagePullSecrets`; tags are immutable SHAs in lower envs, semver in prod.

**6. Delivery (GitOps)**
- **ArgoCD** watches `zen-gitops` `main` branch.
- **dev**: 8–9 individual ArgoCD Applications, **automated sync + selfHeal**.
- **qa/prod**: **app-of-apps** for atomic multi-service deploys; **prod = manual sync** (human gate after PR merge).
- Promotion: CI opens PRs updating `envs/<env>/values-*.yaml` image tags — audit trail in Git.

**7. Observability**
- **Prometheus** scrapes Spring Boot `/actuator/prometheus` endpoints.
- **Grafana** dashboards (values in `k8s/monitoring/`).
- Health: liveness `/actuator/health`, readiness `/actuator/health/readiness` — failed readiness removes pod from Service endpoints.

**8. Security and governance (cross-cutting)**
- **Namespace RBAC** — dev team cannot `exec` into prod pods.
- **ArgoCD AppProject** scopes which namespaces/repos an app can touch.
- **Branch protection + CODEOWNERS** on `envs/prod/`.
- **Network policies** (where enabled) restrict east–west traffic between namespaces.

---

### Why this design (talking points for the interview)

| Decision | Rationale |
|----------|-----------|
| EKS + namespaces vs 3 clusters | Lower cost and ops burden for training/small prod; namespaces + RBAC give env isolation |
| Microservices + api-gateway | Independent deploy/scale per domain; gateway centralizes auth routing and cross-cutting concerns |
| GitOps (ArgoCD) | Declarative state, PR audit trail, rollback = git revert — important in regulated pharma |
| RDS vs in-cluster Postgres | Managed backups, Multi-AZ option, patching — don't run stateful DB on Kubernetes for prod |
| ESO + Secrets Manager | Secrets rotation and audit in AWS; Git stays free of credentials |
| Shared Helm chart | DRY — one chart, per-service values; consistent probes, labels, HPA patterns |

---

### One-minute elevator version

> "Zen Pharma runs nine containerized services on AWS EKS in us-east-1, split across dev, qa, and prod namespaces. Traffic enters through NGINX Ingress to api-gateway and pharma-ui. Backends are Spring Boot microservices talking to environment-specific RDS PostgreSQL. Secrets come from AWS Secrets Manager via External Secrets and IRSA. Images live in ECR; ArgoCD in the cluster syncs desired state from the zen-gitops repo after CI updates image tags through PRs. Prometheus and Grafana give us observability, and prod changes require CODEOWNERS approval plus manual ArgoCD sync."

---

## BS2

### Question
> "Explain the disaster recovery (DR) architecture for Zen Pharma. What are you protecting against, what are your RTO/RPO targets, and how would you recover from a regional outage or database failure?"

### What the interviewer is really testing
- Do you know DR fundamentals (RTO, RPO, backup, restore, failover)?
- Can you map DR concepts to this specific stack (EKS, RDS, GitOps)?
- Pragmatism — what is actually implemented vs what you would add for true enterprise DR?

---

### Model Answer

**Disaster recovery** is the set of people, processes, and technology that lets you **restore acceptable service** after a failure — from a single pod crash (handled by Kubernetes) to losing an entire AWS Availability Zone or Region.

---

### DR fundamentals (define these first in the interview)

| Term | Definition | Zen Pharma example |
|------|------------|-------------------|
| **RTO** (Recovery Time Objective) | Max acceptable **downtime** before service is restored | Prod target: **4 hours** (business); dev/qa: **24 hours** |
| **RPO** (Recovery Point Objective) | Max acceptable **data loss** measured in time | Prod DB: **15 minutes** (RDS PITR window); app config: **0** (Git is source of truth) |
| **RPO vs backup frequency** | If you backup hourly, worst case you lose ~1 hour of data unless continuous replication | RDS automated backups + transaction logs enable finer RPO |
| **HA** (High Availability) | Stay up during **component** failure (single node, single AZ) | Multi-AZ RDS, EKS across 3 AZs, multiple pod replicas |
| **DR** (Disaster Recovery) | Recover after **large** failure (region loss, corruption, ransomware) | Cross-region backups, runbook, secondary cluster |
| **Backup** | Point-in-time copy of data/config | RDS snapshots, Secrets Manager versioning, Git history |
| **Restore** | Rebuild from backup into a working system | Restore RDS snapshot; ArgoCD re-syncs cluster from Git |
| **Failover** | Switch traffic/workload to standby | DNS cutover to DR region; promote RDS read replica |
| **Failback** | Return to primary after DR event | Sync data back, cut DNS back, decommission DR resources |
| **Cold / Warm / Hot standby** | How ready the DR environment is before disaster | This platform: **warm** app config (Git), **cold/warm** infra (Terraform), RDS cross-region replica optional |

---

### What we protect (assets and failure modes)

| Asset | Failure modes | Primary protection | DR mechanism |
|-------|---------------|-------------------|--------------|
| **Application state** (Deployments, Services) | Cluster loss, bad deploy | Git (`zen-gitops`) + ArgoCD | Re-provision EKS; ArgoCD syncs from Git — **RPO ≈ 0** for manifests |
| **Container images** | ECR regional outage | ECR in us-east-1 | Replicate ECR to `us-west-2`; pull from DR registry |
| **Database** | AZ failure, corruption, accidental DROP | RDS Multi-AZ (HA) | Automated backups + **PITR**; cross-region snapshot copy |
| **Secrets** | Secrets Manager outage, accidental delete | Versioning + IAM | Replicate secrets to DR region; ESO re-sync |
| **Terraform state** | State bucket loss | S3 versioning + locking | Restore state object; `terraform apply` rebuilds infra |
| **ArgoCD config** | argocd namespace lost | Git (`argocd/` in zen-gitops) | Reinstall ArgoCD; re-apply Applications from Git |

**What Kubernetes handles without a DR plan:** single pod crash (ReplicaSet), node drain (scheduler + PDB), rolling deploy failure (readiness probe blocks bad rollout).

**What Kubernetes does NOT handle:** entire region unavailable, RDS deleted without backup, ransomware encrypting backups, Git repo deleted without mirror.

---

### Current-state architecture (single region — us-east-1)

```
                    PRIMARY REGION: us-east-1
┌─────────────────────────────────────────────────────────────┐
│  VPC (3 AZs: us-east-1a, 1b, 1c)                            │
│                                                             │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │
│  │   AZ-1a     │   │   AZ-1b     │   │   AZ-1c     │        │
│  │ EKS nodes   │   │ EKS nodes   │   │ EKS nodes   │        │
│  │ (pods spread│   │             │   │             │        │
│  │  via anti-  │   │             │   │             │        │
│  │  affinity)  │   │             │   │             │        │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘        │
│         └─────────────────┼─────────────────┘               │
│                           │                                 │
│              ┌────────────▼────────────┐                    │
│              │  RDS PostgreSQL         │                    │
│              │  Multi-AZ (sync standby)│  ← HA within region │
│              │  Automated backups      │                    │
│              │  PITR (35-day window)   │                    │
│              └─────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘

DR REGION (target): us-west-2  [documented / partially implemented]
┌─────────────────────────────────────────────────────────────┐
│  Cross-region RDS snapshot copy (daily)                     │
│  ECR replication (optional)                                 │
│  Terraform-ready VPC + EKS (cold/warm — provision on declare) │
│  ArgoCD → same zen-gitops repo (region-agnostic desired state)│
└─────────────────────────────────────────────────────────────┘
```

---

### Tiered DR strategy (match response to scenario)

**Tier 1 — Component failure (minutes, automated)**
- Pod OOM / crash → Kubernetes restarts; HPA scales if needed.
- Single AZ degradation → EKS schedules pods on healthy AZs; RDS Multi-AZ fails over DB to standby AZ (**~60–120 seconds** for RDS failover).
- Bad deployment → readiness probe fails; rollout pauses; **Git revert + ArgoCD sync** or `argocd app rollback`.

**Tier 2 — Data corruption or logical error (hours, semi-automated)**
- Wrong migration / bad data → **RDS point-in-time restore** to timestamp before incident.
- Steps:
  1. Identify incident time → choose restore time (RPO).
  2. Restore RDS to **new instance** (never overwrite prod in place).
  3. Update `DB_HOST` in `envs/prod/values-*.yaml` via emergency PR.
  4. ArgoCD sync → pods reconnect to restored DB.
  5. Validate data; cut over; decommission broken instance after root-cause analysis.

**Tier 3 — Cluster loss, AZ-wide EKS failure (hours)**
- EKS control plane is regional — usually AWS restores it.
- If worker nodes are gone but control plane OK → scale node group; ArgoCD re-syncs apps from Git (**RTO: 1–2 hours**).
- If entire cluster unusable:
  1. `terraform apply` in `zen-infra` for new EKS (or restore from IaC).
  2. Install ArgoCD, ESO, ingress, Prometheus from `zen-gitops`.
  3. Point Applications at existing RDS endpoint (if RDS survived).
  4. DNS still points to same ALB/ingress once NLB is recreated.

**Tier 4 — Regional disaster (us-east-1 down) (hours to days)**
- Declare disaster; execute **regional DR runbook**.
- **RTO target: 4–8 hours** (depends on whether DR EKS is warm or cold).
- **RPO target: 15 min – 24 hours** (depends on cross-region RDS replica vs snapshot-only).

Runbook outline:
```
1. Incident commander declares Tier-4 DR
2. Restore RDS from latest cross-region snapshot → us-west-2
   (or promote cross-region read replica if configured)
3. Provision DR EKS (Terraform) OR activate warm standby cluster
4. Update env-specific values: DB_HOST, ECR region, ingress DNS
5. ArgoCD sync all prod apps from zen-gitops (unchanged image tags)
6. Route 53 failover: prod.pharma.internal → DR ingress ALB
7. Smoke tests: auth login, catalog read, manufacturing write path
8. Communicate RTO met / known gaps (e.g. in-flight transactions lost)
9. Post-incident: failback plan when primary region returns
```

---

### Backup inventory (what to back up and how often)

| Component | Backup method | Frequency | Retention | Restore test |
|-----------|---------------|-----------|-----------|----------------|
| RDS PostgreSQL | Automated snapshots + PITR | Continuous (WAL) + daily snapshot | 35 days (configurable) | Quarterly restore to QA |
| AWS Secrets Manager | Automatic versioning | On every change | Per AWS policy | Rotate + verify ESO sync |
| zen-gitops | GitHub (main + tags) | Every commit | Indefinite | Clone repo; ArgoCD bootstrap |
| ECR images | Immutable tags + lifecycle | Per CI push | 90 days untagged | Pull by digest in DR |
| Terraform state | S3 versioning | Per apply | 90 days | Restore version; re-apply |
| Prometheus metrics | Short retention in-cluster | N/A for DR | 15 days | Not critical for DR; use CloudWatch/long-term store for audit |

**3-2-1 rule (state in interview):** 3 copies of data, 2 different media, 1 offsite — here: primary RDS + automated snapshot + cross-region snapshot copy.

---

### RTO / RPO summary table (recommended targets)

| Scenario | RPO | RTO | Mechanism |
|----------|-----|-----|-----------|
| Pod / node failure | 0 | < 5 min | K8s self-healing, Multi-AZ |
| RDS AZ failover | ~0 (sync replica) | 1–2 min | RDS Multi-AZ automatic |
| Accidental table drop | 5–15 min | 1–4 hours | RDS PITR to new instance |
| EKS cluster rebuild | 0 (Git) | 2–4 hours | Terraform + ArgoCD bootstrap |
| Full region loss | 15 min – 24 h | 4–8 hours | Cross-region RDS + DR EKS + DNS failover |

---

### GitOps advantage in DR

> "Our **desired application state is in Git**, not only in the cluster. If we lose the entire EKS cluster but still have RDS and ECR, recovery is: rebuild cluster from Terraform, reinstall platform components, point ArgoCD at zen-gitops — and we're back to the last approved prod manifests. That's why RPO for **configuration** is effectively zero. Data RPO is governed by RDS backup strategy."

---

### Testing DR (what mature teams do)

- **Game days** twice a year: simulate RDS restore, cluster rebuild, DNS failover.
- **Chaos engineering** in QA: kill AZ, drain nodes, verify PDB + anti-affinity.
- **Documented runbooks** in Confluence/wiki with exact commands (not tribal knowledge).
- **Measure actual RTO** during tests — if restore took 6 hours, update the SLA or improve automation.

---

### Honest gap analysis (shows maturity)

For this training platform, **full active-active multi-region** is not implemented — that would double cost. What we have:
- Multi-AZ RDS and multi-AZ EKS worker spread
- GitOps config survivability
- RDS automated backup + PITR
- Cross-region DR is **documented/runbook-based** — enable ECR replication + RDS cross-region snapshots in `zen-infra` for production hardening

**Closing line for the interview:**

> "HA keeps us running when something small breaks; DR is how we come back when something big breaks. For Zen Pharma, GitOps gives us fast application recovery; RDS PITR gives us data recovery; and regional DR is the layer we'd activate only for a true region-wide outage — with RTO measured in hours, not seconds, unless we invest in a warm standby cluster."
