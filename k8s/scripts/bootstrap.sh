#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — SRE Demo Platform: First-Time Setup v2
# =============================================================================
# Run ONCE on a fresh machine before anything else.
# After this, use: bash scripts/start.sh  (from k8s/) after every reboot.
#
# Prerequisites:
#   1. Docker Desktop: https://www.docker.com/products/docker-desktop/
#      Settings → Resources → 24GB RAM, 8 CPU → Apply & Restart
#      Settings → Kubernetes → Enable Kubernetes → Apply & Restart
#   2. brew install kubectl k6
#
# Usage (from k8s/ directory):
#   bash scripts/bootstrap.sh
#
# KEY CHANGES vs v1:
#   [v2] metrics-server source changed to cluster/metrics-server.yaml.
#        Previously applied via infrastructure.yaml (dual source of truth).
#        infrastructure.yaml now only deploys kube-state-metrics + node-exporter.
#        This matches start.sh v5 and resume() in manage.sh — all three scripts
#        now use the same single canonical source for metrics-server.
#   [v2] Local registry setup added.
#        bootstrap.sh previously assumed the patched frontend image was already
#        in the registry. Now it starts the registry and prints rebuild instructions
#        so first-time setup is self-contained.
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

for cmd in kubectl k6 curl python3 docker; do
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

# ── Phase 2: Namespaces + PriorityClasses ─────────────────────────────────────
log "Phase 2: Creating namespaces and PriorityClasses..."
kubectl apply -f "$ROOT/namespaces/priority-classes.yaml"
kubectl apply -f "$ROOT/namespaces/namespaces.yaml"
ok "PriorityClasses + namespaces ready"

# ── Phase 3: metrics-server ───────────────────────────────────────────────────
log "Phase 3: Deploying metrics-server..."
# Single source of truth: cluster/metrics-server.yaml
# infrastructure.yaml does NOT contain metrics-server.
if ! kubectl apply -f "$ROOT/cluster/metrics-server.yaml" 2>/dev/null; then
  warn "metrics-server apply failed (immutable selector) — forcing recreate..."
  kubectl delete deployment metrics-server -n kube-system --ignore-not-found 2>/dev/null
  kubectl apply -f "$ROOT/cluster/metrics-server.yaml"
fi
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
ok "metrics-server ready (v0.7.2, --kubelet-insecure-tls)"

# ── Phase 4: Observability stack ──────────────────────────────────────────────
log "Phase 4: Deploying observability stack..."
log "This pulls ~2GB of images on first run — patience..."

# kube-state-metrics + node-exporter only (metrics-server is handled above)
kubectl apply -f "$ROOT/observability/infrastructure/infrastructure.yaml"
kubectl rollout status deployment/kube-state-metrics -n observability --timeout=120s
ok "kube-state-metrics + node-exporter ready"

kubectl apply -f "$ROOT/observability/prometheus/prometheus.yaml"
kubectl apply -f "$ROOT/observability/loki/loki.yaml"
kubectl apply -f "$ROOT/observability/tempo/tempo.yaml"

log "Waiting for backends to be ready..."
kubectl rollout status deployment/prometheus -n observability --timeout=180s
kubectl rollout status deployment/loki       -n observability --timeout=180s
kubectl rollout status deployment/tempo      -n observability --timeout=180s
ok "Prometheus, Loki, Tempo ready"

kubectl apply -f "$ROOT/observability/alloy/alloy.yaml"
kubectl rollout status daemonset/alloy -n observability --timeout=120s
ok "Alloy ready (OTLP collector + log shipper — DaemonSet)"

kubectl apply -f "$ROOT/observability/grafana/grafana.yaml"
kubectl rollout status deployment/grafana -n observability --timeout=120s
ok "Grafana ready (dashboards pre-loaded, PVC-backed)"

# ── Phase 5: Local registry + patched frontend ────────────────────────────────
log "Phase 5: Local Docker registry for patched frontend image..."
if docker ps --format '{{.Names}}' | grep -q "^local-registry$"; then
  ok "Local registry already running"
else
  docker run -d -p 5001:5000 --name local-registry registry:2 2>/dev/null || \
    docker start local-registry 2>/dev/null || true
  sleep 2
  ok "Local registry started on :5001"
fi

if docker manifest inspect localhost:5001/boutique-frontend:arm64-v1 &>/dev/null 2>&1; then
  ok "Patched frontend image present in registry ✓"
else
  warn "Patched frontend image NOT found — frontend will ImagePullBackOff."
  warn ""
  warn "Build and push the image:"
  warn "  1. Clone sparse frontend source:"
  warn "     mkdir -p /tmp/boutique-patch && cd /tmp/boutique-patch"
  warn "     git init && git remote add origin https://github.com/GoogleCloudPlatform/microservices-demo"
  warn "     git sparse-checkout set src/frontend && git pull origin main"
  warn ""
  warn "  2. Apply the one-line patch to src/frontend/rpc.go:"
  warn "     avoidNoopCurrencyConversionRPC = true"
  warn ""
  warn "  3. Build and push:"
  warn "     docker buildx build --platform linux/arm64 \\"
  warn "       --build-arg TARGETARCH=arm64 --build-arg TARGETOS=linux \\"
  warn "       --load -t boutique-frontend:arm64-v1 src/frontend/"
  warn "     docker tag boutique-frontend:arm64-v1 localhost:5001/boutique-frontend:arm64-v1"
  warn "     docker push localhost:5001/boutique-frontend:arm64-v1"
  warn ""
  warn "Continuing bootstrap — all other services will deploy normally."
fi

# ── Phase 6: Boutique application ─────────────────────────────────────────────
log "Phase 6: Deploying Online Boutique..."
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

# ── Phase 7: Port-forwards ────────────────────────────────────────────────────
log "Phase 7: Starting port-forwards..."
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

# ── Phase 8: Smoke tests ──────────────────────────────────────────────────────
log "Phase 8: Smoke tests..."

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
echo -e "  Boutique     http://localhost:8080"
echo -e "  Grafana      http://localhost:3000   admin / admin"
echo -e "  Prometheus   http://localhost:9090"
echo -e "  Alloy UI     http://localhost:12345"
echo ""
echo -e "  Grafana dashboards (pre-loaded, survive pod restarts):"
echo -e "    - SRE Command Center"
echo -e "    - Golden Signals — Deep Dive"
echo -e "    - Infrastructure & Node"
echo -e "    - Platform & HPA"
echo -e "    - SLO & Error Budget"
echo ""
echo -e "  Next steps:"
echo -e "    Smoke test:        k6 run scripts/load-test_10vusers.js"
echo -e "    100 VU:            k6 run scripts/load-test_100vusers.js"
echo -e "    1000 VU:           k6 run scripts/load-test_1000vusers.js"
echo -e "    Stability harness: bash scripts/verify-stability.sh --short"
echo -e "    HPA watch:         bash scripts/manage.sh hpa-watch"
echo -e "    Full debug:        bash scripts/manage.sh debug"
echo ""
echo -e "  After every reboot:  bash scripts/start.sh"
echo -e "  Suspend (free RAM):  bash scripts/manage.sh suspend"
echo -e "  Resume:              bash scripts/manage.sh resume"
echo -e "  Full reset:          bash scripts/manage.sh nuke"
echo ""
