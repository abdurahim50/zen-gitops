# zen-gitops

GitOps configuration repository for the Zen Pharma platform.
ArgoCD watches this repo and syncs all changes to the EKS cluster automatically.

> **Companion repos:**
> - [`zen-infra`](https://github.com/your-github-username/zen-infra) — Terraform for AWS infrastructure (EKS, RDS, ECR, IAM)
> - [`zen-pharma-backend`](https://github.com/your-github-username/zen-pharma-backend) — Spring Boot microservices
> - [`zen-pharma-frontend`](https://github.com/your-github-username/zen-pharma-frontend) — React frontend

> **Note:** Replace `your-github-username` in all `repoURL` fields inside `argocd/` with your actual GitHub username after forking.

---

## What Lives Here

| Folder | Purpose |
|--------|---------|
| `helm-charts/` | Shared Helm chart used by all 8 services |
| `envs/` | Per-environment Helm values files (dev / qa / prod) |
| `argocd/` | ArgoCD AppProject + per-service Application manifests |
| `k8s/` | Cluster-level configs — namespaces, RBAC, External Secrets, ingress values |
| `db-init/` | PostgreSQL schema initialisation scripts |

---

## Repository Structure

```
zen-gitops/
├── helm-charts/                        # Shared Helm chart (one chart, all 8 services)
│   ├── Chart.yaml
│   ├── values.yaml                     # Default values (overridden per service)
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── configmap.yaml
│       ├── serviceaccount.yaml
│       ├── hpa.yaml
│       └── _helpers.tpl
│
├── envs/                               # Per-environment Helm values
│   ├── dev/
│   │   ├── values-api-gateway.yaml
│   │   ├── values-auth-service.yaml
│   │   ├── values-catalog-service.yaml
│   │   ├── values-inventory-service.yaml
│   │   ├── values-manufacturing-service.yaml
│   │   ├── values-notification-service.yaml
│   │   ├── values-pharma-ui.yaml
│   │   └── values-supplier-service.yaml
│   ├── qa/                             # Same 8 files, QA-specific values
│   └── prod/                           # Same 8 files, prod-specific values + podAntiAffinity
│
├── argocd/
│   ├── install/
│   │   ├── argocd-namespace.yaml       # argocd namespace definition
│   │   └── argocd-ingress.yaml         # ArgoCD UI ingress
│   ├── projects/
│   │   └── pharma-project.yaml         # ArgoCD AppProject (scopes allowed repos/namespaces)
│   └── apps/
│       ├── dev/                        # Individual Application per service (8 apps)
│       │   ├── api-gateway-app.yaml
│       │   ├── auth-service-app.yaml
│       │   ├── catalog-service-app.yaml
│       │   ├── inventory-service-app.yaml
│       │   ├── manufacturing-service-app.yaml
│       │   ├── notification-service-app.yaml
│       │   ├── pharma-ui-app.yaml
│       │   └── supplier-service-app.yaml
│       ├── qa/
│       │   └── pharma-qa-app.yaml      # Single app-of-apps pointing to envs/qa/
│       └── prod/
│           └── pharma-prod-app.yaml    # Single app-of-apps pointing to envs/prod/
│
├── k8s/                                # Cluster-level Kubernetes configs
│   ├── namespaces.yaml
│   ├── rbac/                           # Role and RoleBinding per environment
│   ├── external-secrets/               # ClusterSecretStore + ExternalSecrets per env
│   ├── ingress/                        # NGINX Ingress Helm values
│   └── monitoring/                     # Prometheus Helm values
│
└── db-init/
    └── 01-schemas.sql                  # Creates schemas: pharmacy, inventory, procurement, manufacturing
```

---

## How Helm Works Here

One chart (`helm-charts/`) is shared across all 8 services.
Each service gets its own values file that overrides the defaults:

```
helm-charts/values.yaml                 <- defaults (replicas, probes, resources)
      +
envs/dev/values-auth-service.yaml       <- service-specific overrides (port, image tag, env vars)
      =
Final Kubernetes manifests for auth-service in the dev namespace
```

ArgoCD Application for a service:
```yaml
source:
  # Replace 'your-github-username' with your GitHub username
  repoURL: https://github.com/your-github-username/zen-gitops.git
  path: helm-charts
  helm:
    valueFiles:
      - ../envs/dev/values-auth-service.yaml
```

---

## ArgoCD Sync Policy per Environment

| Environment | App structure | Sync policy | Who triggers deploy |
|---|---|---|---|
| `dev` | 8 individual Applications | Automated + selfHeal | CI commits image tag → ArgoCD auto-syncs |
| `qa` | 1 `pharma-qa` app-of-apps | Automated + selfHeal | QA promotion PR merged → ArgoCD auto-syncs |
| `prod` | 1 `pharma-prod` app-of-apps | **Manual sync** | PROD PR merged → engineer triggers sync in ArgoCD UI |

---

## Updating an Image Tag (how CI does it)

CI workflow in `zen-pharma-backend` updates the image tag after a successful build:

```bash
# Example: update auth-service to sha-a1b2c3d in dev
yq e '.image.tag = "sha-a1b2c3d"' -i envs/dev/values-auth-service.yaml
git add envs/dev/values-auth-service.yaml
git commit -m "ci(dev): update auth-service -> sha-a1b2c3d"
git push
# ArgoCD detects the commit and syncs dev within 3 minutes
```

---

## Environment Differences

| Setting | dev | qa | prod |
|---|---|---|---|
| `replicaCount` | 1 | 1 | HPA-managed (min 2) |
| `autoscaling.minReplicas` | disabled | 1 | 2 |
| `autoscaling.maxReplicas` | disabled | 3 | 5 |
| `podDisruptionBudget` | disabled | disabled | enabled (`minAvailable: 1`) |
| `networkPolicy` | disabled | disabled | enabled (ingress from NGINX or api-gateway) |
| `LOG_LEVEL` | DEBUG | INFO | WARN |
| `podAntiAffinity` | no | no | yes (pods spread across nodes) |
| CPU request/limit | 100m / 500m | 150m / 500m | 250m / 1000m |
| Memory request/limit | 256Mi / 512Mi | 256Mi / 512Mi | 512Mi / 1Gi |

---

## Full Setup Guide

See `zen-infra/docs/FULL-DEPLOYMENT-GUIDE.md` in the `zen-infra` repository for the complete
step-by-step guide covering all 4 stages: infra → prerequisites → CI → ArgoCD CD.
