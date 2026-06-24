#!/usr/bin/env bash
# =============================================================================
# Observability Stack Setup — EBS CSI Driver + Fluent Bit + Prometheus/Grafana
# Cluster : pharma-dev-cluster  |  Region: us-east-1
# Run from: zen-gitops root
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()    { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER="pharma-dev-cluster"
REGION="us-east-1"
EBS_SA="ebs-csi-controller-sa"
EBS_POLICY="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
REPO_ROOT="$(git rev-parse --show-toplevel)"
ARGOCD_NS="argocd"
ARGOCD_SERVER="localhost:8080"

# =============================================================================
# STEP 0 — Prerequisites check
# =============================================================================
echo ""
info "=== STEP 0: Checking prerequisites ==="

for tool in kubectl aws eksctl argocd; do
  if ! command -v "$tool" &>/dev/null; then
    fail "$tool is not installed. Please install it first."
  fi
  success "$tool found"
done

kubectl cluster-info --request-timeout=5s &>/dev/null \
  || fail "Cannot reach Kubernetes cluster. Check your kubeconfig."
success "Cluster reachable: $CLUSTER"

# =============================================================================
# STEP 1 — EBS CSI Driver (prerequisite for persistent storage)
# =============================================================================
echo ""
info "=== STEP 1: EBS CSI Driver ==="

# 1a. IRSA — skip if role already annotated on the service account
if kubectl get serviceaccount "$EBS_SA" -n kube-system \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' \
     2>/dev/null | grep -q "arn:aws:iam"; then
  success "IRSA role already exists on $EBS_SA — skipping creation"
else
  info "Creating IRSA role for EBS CSI controller..."
  eksctl create iamserviceaccount \
    --name "$EBS_SA" \
    --namespace kube-system \
    --cluster "$CLUSTER" \
    --region "$REGION" \
    --attach-policy-arn "$EBS_POLICY" \
    --approve \
    --override-existing-serviceaccounts
  success "IRSA role created"
fi

EBS_ROLE_ARN=$(kubectl get serviceaccount "$EBS_SA" -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
info "EBS CSI role ARN: $EBS_ROLE_ARN"

# 1b. Install addon — skip if already ACTIVE
ADDON_STATUS=$(aws eks describe-addon \
  --cluster-name "$CLUSTER" \
  --addon-name aws-ebs-csi-driver \
  --region "$REGION" \
  --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$ADDON_STATUS" == "ACTIVE" ]]; then
  success "aws-ebs-csi-driver addon already ACTIVE — skipping"
elif [[ "$ADDON_STATUS" == "CREATE_FAILED" ]]; then
  warn "Previous addon install failed. Deleting and reinstalling..."
  aws eks delete-addon --cluster-name "$CLUSTER" \
    --addon-name aws-ebs-csi-driver --region "$REGION" &>/dev/null
  until ! aws eks describe-addon --cluster-name "$CLUSTER" \
    --addon-name aws-ebs-csi-driver --region "$REGION" &>/dev/null; do sleep 5; done
  ADDON_STATUS="NOT_FOUND"
fi

if [[ "$ADDON_STATUS" == "NOT_FOUND" ]]; then
  info "Installing aws-ebs-csi-driver addon..."
  aws eks create-addon \
    --cluster-name "$CLUSTER" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --region "$REGION" &>/dev/null
fi

# 1c. Wait for ACTIVE
info "Waiting for EBS CSI addon to become ACTIVE..."
for i in $(seq 1 30); do
  STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER" \
    --addon-name aws-ebs-csi-driver --region "$REGION" \
    --query 'addon.status' --output text 2>/dev/null)
  [[ "$STATUS" == "ACTIVE" ]] && { success "EBS CSI addon is ACTIVE"; break; }
  [[ "$STATUS" == "CREATE_FAILED" ]] && fail "EBS CSI addon failed to install. Check IAM permissions."
  echo -n "."
  sleep 10
done
echo ""

# 1d. Verify CSI pods
kubectl wait pod -n kube-system \
  -l app.kubernetes.io/name=aws-ebs-csi-driver \
  --for=condition=Ready --timeout=60s &>/dev/null \
  && success "EBS CSI pods Running" \
  || warn "EBS CSI pods not fully ready yet (may still be starting)"

# =============================================================================
# STEP 2 — Apply ArgoCD Project (ensures kube-system destination is allowed)
# =============================================================================
echo ""
info "=== STEP 2: ArgoCD Project ==="
kubectl apply -f "$REPO_ROOT/argocd/projects/pharma-project.yaml" &>/dev/null
success "pharma ArgoCD project applied"

# =============================================================================
# STEP 3 — Port-forward ArgoCD and login
# =============================================================================
echo ""
info "=== STEP 3: ArgoCD login ==="

# Kill any stale port-forward on 8080
pkill -f "port-forward.*argocd-server" 2>/dev/null || true
sleep 2

kubectl port-forward svc/argocd-server -n "$ARGOCD_NS" 8080:80 &>/dev/null &
PF_PID=$!
sleep 4

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "$ARGOCD_NS" -o jsonpath='{.data.password}' | base64 -d)

argocd login "$ARGOCD_SERVER" \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure &>/dev/null
success "Logged in to ArgoCD"

# =============================================================================
# STEP 4 — Deploy Fluent Bit via ArgoCD
# =============================================================================
echo ""
info "=== STEP 4: Fluent Bit ==="
kubectl apply -f "$REPO_ROOT/observability_project4/fluent-bit-app.yaml" &>/dev/null
success "fluent-bit-dev ArgoCD app applied"

# Wait for Fluent Bit pods
info "Waiting for Fluent Bit pods to be Running..."
for i in $(seq 1 18); do
  READY=$(kubectl get pods -n dev -l app=fluent-bit \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$READY" -ge 1 ]] && { success "Fluent Bit pods Running ($READY)"; break; }
  echo -n "."
  sleep 10
done
echo ""

# =============================================================================
# STEP 5 — Deploy Prometheus + Grafana via ArgoCD
# =============================================================================
echo ""
info "=== STEP 5: Prometheus + Grafana (kube-prometheus-stack) ==="
kubectl apply -f "$REPO_ROOT/argocd/apps/dev/monitoring-app.yaml" &>/dev/null
success "monitoring ArgoCD app applied"

# Trigger sync (automated policy will also kick in)
argocd app sync monitoring --server "$ARGOCD_SERVER" --async 2>/dev/null || true

# 5a. Wait for Grafana PVC to bind
info "Waiting for Grafana PVC to bind..."
for i in $(seq 1 18); do
  STATUS=$(kubectl get pvc grafana -n monitoring \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "$STATUS" == "Bound" ]] && { success "Grafana PVC Bound (gp2-csi, 10Gi)"; break; }
  echo -n "."
  sleep 10
done
echo ""

# 5b. Wait for core monitoring pods
info "Waiting for monitoring pods (this takes 3-5 min for EBS volumes to provision)..."
for i in $(seq 1 36); do
  READY=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -v "Completed\|Terminating" \
    | awk '{print $2}' \
    | awk -F'/' '$1==$2' | wc -l | tr -d ' ')
  TOTAL=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -v "Completed\|Terminating" | wc -l | tr -d ' ')
  [[ "$TOTAL" -gt 0 && "$READY" -eq "$TOTAL" ]] && { success "All monitoring pods Ready ($READY/$TOTAL)"; break; }
  echo -n "($READY/$TOTAL) "
  sleep 10
done
echo ""

# =============================================================================
# STEP 6 — Verify PodMonitor for Fluent Bit
# =============================================================================
echo ""
info "=== STEP 6: Fluent Bit PodMonitor ==="
if kubectl get podmonitor fluent-bit -n monitoring &>/dev/null; then
  success "PodMonitor 'fluent-bit' exists in monitoring namespace"
else
  warn "PodMonitor not found — applying manually"
  kubectl apply -f "$REPO_ROOT/k8s/monitoring/fluent-bit-podmonitor.yaml"
fi

# =============================================================================
# DONE — Print access summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Observability Stack Ready${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  GRAFANA"
echo "    Port-forward : kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
echo "    URL          : http://localhost:3000"
echo "    Username     : admin"
echo "    Password     : pharma-grafana-2026"
echo ""
echo "  PROMETHEUS"
echo "    Port-forward : kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo "    URL          : http://localhost:9090/targets"
echo "    Look for     : podMonitor/monitoring/fluent-bit → UP"
echo ""
echo "  ARGOCD"
echo "    Port-forward : kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "    URL          : http://localhost:8080"
echo "    Username     : admin"
echo "    Password     : $ARGOCD_PASSWORD"
echo ""
echo "  PVCs"
kubectl get pvc -n monitoring 2>/dev/null || true
echo ""

# Cleanup background port-forward
kill "$PF_PID" 2>/dev/null || true
