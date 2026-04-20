#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — SRE Demo Platform: First-Time Setup
# =============================================================================
# Run ONCE on a fresh machine before anything else.
# After this, use: bash scripts/start.sh  (from k8s/) after every reboot.
#
# Prerequisites before running:
#   1. Install Docker Desktop: https://www.docker.com/products/docker-desktop/
#   2. Docker Desktop → Settings → Resources → 24GB RAM, 8 CPU → Apply & Restart
#   3. Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart
#   4. brew install kubectl k6
#
# Usage (from k8s/ directory):
#   bash scripts/bootstrap.sh
#
# Pass 1 change: Alloy is now a DaemonSet (for log collection via hostPath).
# All references to `deployment/alloy` replaced with `daemonset/alloy`.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[bootstrap]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  ROOT="$(dirname "$SCRIPT_DIR")"
else
  ROOT="$SCRIPT_DIR"
fi
cd "$ROOT"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SRE Demo Platform — First-Time Bootstrap${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
log "Working directory: $ROOT"
echo ""

# ── Phase 0: Preflight ───────────────────────────────────────────────────────
log "Phase 0: Preflight checks..."

for cmd in kubectl k6 curl python3; do
  command -v "$cmd" &>/dev/null || die "$cmd not found. Install: brew install $cmd"
  ok "$cmd: $(command -v $cmd)"
done

if ! kubectl cluster-info &>/dev/null; then
  die "Kubernetes not reachable. Enable it: Docker Desktop → Settings → Kubernetes → Enable"
fi
CTX=$(kubectl config current-context)
ok "kubectl context: $CTX"

if [[ "$CTX" != "docker-desktop" ]]; then
  warn "Context is '$CTX', not 'docker-desktop'. Are you on the right cluster?"
  read -r -p "Continue? (y/N) " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || exit 1
fi

NODE_MEM=$(kubectl get node -o jsonpath='{.items[0].status.capacity.memory}' | sed 's/Ki//')
NODE_MEM_GB=$(( NODE_MEM / 1024 / 1024 ))
if [[ $NODE_MEM_GB -lt 20 ]]; then
  warn "Node only has ${NODE_MEM_GB}GB RAM. Recommend 24GB."
  warn "Docker Desktop → Settings → Resources → Memory → 24GB → Apply & Restart"
  sleep 3
else
  ok "Node memory: ${NODE_MEM_GB}GB ✓"
fi

# ── Phase 1: Storage provisioner ─────────────────────────────────────────────
log "Phase 1: Installing local-path storage provisioner..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s
ok "local-path storage provisioner ready"

kubectl get storageclass local-path &>/dev/null \
  && ok "StorageClass local-path present" \
  || die "local-path StorageClass not found after install"

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || true
ok "local-path set as default StorageClass"

# ── Phase 2: Namespaces ───────────────────────────────────────────────────────
log "Phase 2: Creating namespaces..."
kubectl apply -f "$ROOT/namespaces/namespaces.yaml"
ok "Namespaces: observability, boutique"

# ── Phase 3: Observability stack ──────────────────────────────────────────────
log "Phase 3: Deploying observability stack (Prometheus, Loki, Tempo)..."
log "This pulls ~2GB of images on first run — patience..."

kubectl apply -f "$ROOT/observability/prometheus/prometheus.yaml"
kubectl apply -f "$ROOT/observability/loki/loki.yaml"
kubectl apply -f "$ROOT/observability/tempo/tempo.yaml"

log "Waiting for backends to be ready..."
kubectl rollout status deployment/prometheus -n observability --timeout=180s
kubectl rollout status deployment/loki       -n observability --timeout=180s
kubectl rollout status deployment/tempo      -n observability --timeout=180s
ok "Prometheus, Loki, Tempo ready"

kubectl apply -f "$ROOT/observability/infrastructure/infrastructure.yaml"
kubectl rollout status deployment/kube-state-metrics -n observability --timeout=120s
ok "Infrastructure exporters ready (node-exporter, kube-state-metrics, metrics-server)"

kubectl apply -f "$ROOT/observability/alloy/alloy.yaml"
# PASS 1 CHANGE: Alloy is now a DaemonSet for log collection via hostPath
kubectl rollout status daemonset/alloy -n observability --timeout=120s
ok "Alloy ready (OTLP collector + log shipper — DaemonSet)"

kubectl apply -f "$ROOT/observability/grafana/grafana.yaml"
kubectl rollout status deployment/grafana -n observability --timeout=120s
ok "Grafana ready (3 dashboards pre-loaded, PVC-backed)"

# ── Phase 4: Boutique application ─────────────────────────────────────────────
log "Phase 4: Deploying Online Boutique..."
log "adservice (Java JVM) and cartservice (C# .NET) are slow on first pull — normal."

kubectl apply -f "$ROOT/boutique/boutique.yaml"

log "Waiting for frontend (this waits for all downstream services too)..."
kubectl rollout status deployment/frontend -n boutique --timeout=480s \
  || warn "Frontend timeout — check: kubectl get pods -n boutique"
ok "Online Boutique ready"

log "Waiting 45s for metrics-server API to register before applying HPA..."
sleep 45
kubectl apply -f "$ROOT/boutique/hpa.yaml"
ok "HPA policies applied"

# ── Phase 5: Port-forwards ────────────────────────────────────────────────────
log "Phase 5: Starting port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2

_pf() { kubectl port-forward -n "$1" "svc/$2" "$3:$4" &>"/tmp/pf-$2.log" & }
_pf boutique      frontend   8080  8080
_pf observability grafana    3000  3000
_pf observability prometheus 9090  9090
_pf observability alloy      12345 12345
_pf observability tempo      3200  3200
_pf observability loki       3100  3100
sleep 8

# ── Phase 6: Smoke tests ──────────────────────────────────────────────────────
log "Phase 6: Smoke tests..."

chk() {
  local name=$1 url=$2
  if curl -sf "$url" -o /dev/null -m 8 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $name"
  else
    echo -e "  ${YELLOW}~${NC} $name — may still be starting (check in 30s)"
  fi
}

chk "Boutique"   "http://localhost:8080"
chk "Grafana"    "http://localhost:3000/api/health"
chk "Prometheus" "http://localhost:9090/-/healthy"
chk "Alloy UI"   "http://localhost:12345/-/ready"
chk "Tempo"      "http://localhost:3200/ready"
chk "Loki"       "http://localhost:3100/ready"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Bootstrap COMPLETE — Stack is READY${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Boutique     http://localhost:8080   (NodePort: :30080)"
echo -e "  Grafana      http://localhost:3000   admin / admin"
echo -e "  Prometheus   http://localhost:9090"
echo -e "  Alloy UI     http://localhost:12345"
echo ""
echo -e "  Grafana dashboards (pre-loaded, survive pod restarts):"
echo -e "    - Boutique — Golden Signals"
echo -e "    - Boutique — Pod & Platform Stats"
echo -e "    - Boutique — SLI / SLO / Error Budget"
echo ""
echo -e "  Next steps:"
echo -e "    Verify pipelines:  bash scripts/manage.sh verify"
echo -e "    Send traffic:      k6 run scripts/load-test_10vusers.js"
echo -e "    Full load test:    k6 run scripts/load-test_1000vusers.js"
echo -e "    Stability harness: bash scripts/verify-stability.sh"
echo -e "    HPA watch:         kubectl get hpa -n boutique -w"
echo ""
echo -e "  After every reboot:  bash scripts/start.sh"
echo -e "  Stop everything:     bash scripts/manage.sh stop"
echo -e "  Full reset:          bash scripts/manage.sh nuke"
echo ""
