#!/bin/bash
# =============================================================================
# start.sh — SRE Demo Platform: Full Startup v6
# =============================================================================
#
# Usage:
#   bash scripts/start.sh              # full startup
#   bash scripts/start.sh --pf-only   # restart port-forwards only
#   bash scripts/start.sh --verify    # re-run pipeline verification only
#
# STARTUP ORDER (do not change — dependencies are load-bearing):
#   0. Preflight
#   1. PriorityClasses + Namespaces
#   2. metrics-server          ← cluster/metrics-server.yaml (single source)
#   3. Observability infra     ← kube-state-metrics, node-exporter only
#   4. Core observability      ← Prometheus, Loki, Tempo
#   5. Alloy
#   6. Grafana
#   7. Local registry check    ← patched frontend image must be present
#   8. Boutique application
#   9. HPA
#  10. Port-forwards
#  11. Warm gate + final status
#
# KEY CHANGES vs v5:
#
# [v6] Port-forward definitions fixed for Docker Desktop macOS.
#      Frontend (boutique) and Grafana/Prometheus are LoadBalancer services —
#      Docker Desktop maps them directly to localhost via the VM network.
#      Port-forwarding these is unnecessary and caused "address already in use"
#      conflicts. PF_DEFS now only port-forwards ClusterIP services:
#        - alloy      :12345  (ClusterIP — UI + metrics endpoint)
#        - tempo      :3200   (ClusterIP — trace search UI)
#        - loki       :3100   (ClusterIP — log query API)
#      These are always available without port-forward:
#        - frontend   :8080   (LoadBalancer → localhost:8080 via Docker Desktop)
#        - grafana    :3000   (LoadBalancer → 172.18.0.x:3000 via Docker Desktop)
#        - prometheus :9090   (LoadBalancer → 172.18.0.x:9090 via Docker Desktop)
#
# [v6] doctor() PVC check updated — loki-pvc added (new in loki.yaml v2).
#      Previous doctor() only checked grafana-pvc, prometheus-pvc, tempo-pvc.
#
# [v6] verify() Loki label check updated — job label is now
#      "loki.source.kubernetes.pods" (loki.source.kubernetes component).
#      Previous check used "pod" label which doesn't exist with API streaming.
#
# [v5] metrics-server source consolidated to cluster/metrics-server.yaml.
# [v5] Local registry check added.
# [v4] wait_warm_gate() — end-to-end HTTP verification before "STACK IS UP".
# [v4] wait_tcp_ready() — TCP probe from inside cluster before frontend wait.
# [v3] NodePort → LoadBalancer :8080 as primary URL.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
else
  REPO_ROOT="$SCRIPT_DIR"
fi
cd "$REPO_ROOT"

MODE="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}▶${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC} $*"; }
section() {
  echo -e "\n${GREEN}════════════════════════════════════════${NC}"
  echo -e "${GREEN} $*${NC}"
  echo -e "${GREEN}════════════════════════════════════════${NC}"
}

# [v6] Only ClusterIP services need port-forwarding.
# LoadBalancer services (frontend, grafana, prometheus) are directly accessible
# via Docker Desktop's VM network bridge — no port-forward needed or wanted.
PF_DEFS=(
  "observability alloy      12345 12345 http://localhost:12345/-/ready"
  "observability tempo      3200  3200  http://localhost:3200/ready"
  "observability loki       3100  3100  http://localhost:3100/ready"
)
PF_PID_FILE="${REPO_ROOT}/.pf-pids"

wait_ready_kind() {
  local kind=$1 name=$2 ns=$3 timeout_sec=${4:-120}
  info "Waiting for $kind/$name ($ns) — up to ${timeout_sec}s..."
  if ! kubectl rollout status "$kind/$name" -n "$ns" \
       --timeout="${timeout_sec}s" 2>/dev/null; then
    warn "$kind/$name timed out — check: kubectl logs -n $ns $kind/$name --tail=40"
    return 1
  fi
  if [[ "$kind" == "deployment" ]]; then
    local ready
    ready=$(kubectl get deployment "$name" -n "$ns" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready:-0}" -lt 1 ]]; then
      warn "$name has 0 ready replicas"
      return 1
    fi
    info "$name → ${ready} replica(s) ready ✓"
  else
    local desired ready
    desired=$(kubectl get daemonset "$name" -n "$ns" \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    ready=$(kubectl get daemonset "$name" -n "$ns" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    info "$name → ${ready}/${desired} pods ready ✓"
  fi
}

start_port_forward() {
  local ns=$1 svc=$2 local_port=$3 remote_port=$4 health_url=$5
  local log_file="/tmp/pf-${svc}.log"
  pkill -f "kubectl port-forward.*${local_port}:" 2>/dev/null || true
  sleep 1
  kubectl port-forward -n "$ns" "svc/$svc" "${local_port}:${remote_port}" \
    > "$log_file" 2>&1 &
  echo $! >> "$PF_PID_FILE"
  local elapsed=0
  while ! curl -sf "$health_url" -o /dev/null -m 3 2>/dev/null; do
    sleep 2; elapsed=$((elapsed + 2))
    if [[ $elapsed -ge 20 ]]; then
      warn "Port-forward for $svc:$local_port did not come up (check $log_file)"
      return 0
    fi
  done
  info "Port-forward $svc:$local_port ready ✓"
}

wait_tcp_ready() {
  local host=$1 port=$2 label=${3:-$1:$2} timeout_sec=${4:-120}
  info "Verifying $label gRPC port is warm (up to ${timeout_sec}s)..."
  local elapsed=0
  local probe_pod
  probe_pod=$(kubectl get pods -n boutique -l app=redis \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$probe_pod" ]]; then
    warn "No redis pod available for TCP probe — skipping $label check"
    return 0
  fi
  while ! kubectl exec -n boutique "$probe_pod" -- \
      sh -c "nc -z $host $port" &>/dev/null 2>&1; do
    sleep 3; elapsed=$((elapsed + 3))
    if [[ $elapsed -ge $timeout_sec ]]; then
      warn "$label did not accept connections after ${timeout_sec}s"
      return 1
    fi
  done
  info "$label accepting connections ✓ (${elapsed}s)"
}

wait_warm_gate() {
  local url=$1 timeout_sec=${2:-180}
  info "Warm gate: polling $url/ until real product page returns (up to ${timeout_sec}s)..."
  info "(Requires productcatalog + currency + recommendation to all be warm)"
  local elapsed=0 http_code
  while true; do
    http_code=$(curl -s "${url}/" -o /tmp/boutique-warmcheck.html \
      -w "%{http_code}" -m 10 --max-time 10 \
      -H "Cookie: shop_session-id=x-warmgate" 2>/dev/null)
    http_code=${http_code:-000}
    if [[ "$http_code" == "200" ]]; then
      if grep -qi "Hot Products\|Sunglasses\|Vintage\|Camera\|Terracycle" \
          /tmp/boutique-warmcheck.html 2>/dev/null; then
        info "Warm gate PASSED — homepage returned real product data ✓ (${elapsed}s)"
        return 0
      fi
      if [[ $elapsed -ge 30 ]]; then
        info "Warm gate PASSED — HTTP 200 sustained ✓ (${elapsed}s)"
        return 0
      fi
    fi
    sleep 5; elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout_sec ]]; then
      warn "Warm gate timed out after ${timeout_sec}s (last HTTP: $http_code)"
      warn "Stack may still be warming — check: curl -v ${url}/"
      return 1
    fi
    [[ $((elapsed % 15)) -eq 0 ]] && \
      info "  ... still warming (${elapsed}s elapsed, last HTTP: $http_code)"
  done
}

# ── --pf-only mode ────────────────────────────────────────────────────────────
if [[ "$MODE" == "--pf-only" ]]; then
  section "Port-forwards only (ClusterIP services)"
  pkill -f "kubectl port-forward" 2>/dev/null || true
  [[ -f "$PF_PID_FILE" ]] && rm "$PF_PID_FILE"
  touch "$PF_PID_FILE"
  for pf in "${PF_DEFS[@]}"; do
    read -r ns svc lp rp url <<< "$pf"
    start_port_forward "$ns" "$svc" "$lp" "$rp" "$url"
  done
  echo ""
  info "Port-forwards started."
  echo ""
  echo "  Alloy UI:   http://localhost:12345"
  echo "  Tempo:      http://localhost:3200"
  echo "  Loki:       http://localhost:3100"
  echo ""
  echo "  (LoadBalancer services — always available without port-forward)"
  FRONTEND_IP=$(kubectl get svc frontend -n boutique \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  GRAFANA_IP=$(kubectl get svc grafana -n observability \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  PROM_IP=$(kubectl get svc prometheus -n observability \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  echo "  Frontend:   http://localhost:8080  (${FRONTEND_IP:-LoadBalancer})"
  echo "  Grafana:    http://${GRAFANA_IP:-172.18.0.x}:3000  admin/admin"
  echo "  Prometheus: http://${PROM_IP:-172.18.0.x}:9090"
  exit 0
fi

# ── --verify mode ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "--verify" ]]; then
  bash "$SCRIPT_DIR/verify-stability.sh" --short
  exit $?
fi

# =============================================================================
# FULL STARTUP
# =============================================================================

section "0. Preflight"
command -v kubectl &>/dev/null || { error "kubectl not found"; exit 1; }
command -v k6     &>/dev/null || warn "k6 not found — load tests will fail (brew install k6)"
command -v docker &>/dev/null || warn "docker not found — local registry check will be skipped"
kubectl cluster-info &>/dev/null || { error "cluster unreachable — is Docker Desktop running?"; exit 1; }
info "Cluster: $(kubectl config current-context)"

total_mem_gb=$(kubectl get node -o jsonpath='{.items[0].status.capacity.memory}' 2>/dev/null \
  | sed 's/Ki$//' | awk '{printf "%.0f", $1/1024/1024}' || echo "0")
if [[ "$total_mem_gb" -lt 16 ]]; then
  warn "Node only has ${total_mem_gb}GB RAM. Recommend 24GB+ for 1000 VU."
else
  info "Node memory: ${total_mem_gb}GB ✓"
fi

section "1. PriorityClasses + Namespaces"
kubectl apply -f namespaces/priority-classes.yaml
kubectl apply -f namespaces/namespaces.yaml
info "PriorityClasses and namespaces ready ✓"

section "2. metrics-server"
if ! kubectl apply -f cluster/metrics-server.yaml 2>/dev/null; then
  warn "metrics-server apply failed (immutable selector) — forcing recreate..."
  kubectl delete deployment metrics-server -n kube-system --ignore-not-found 2>/dev/null
  kubectl apply -f cluster/metrics-server.yaml
fi
wait_ready_kind deployment metrics-server kube-system 120 || \
  warn "metrics-server slow — HPA targets may show <unknown> initially"

section "3. Observability infrastructure (kube-state-metrics + node-exporter)"
kubectl apply -f observability/infrastructure/infrastructure.yaml
kubectl rollout status deployment/kube-state-metrics -n observability \
  --timeout=120s 2>/dev/null && info "kube-state-metrics ✓" || \
  warn "kube-state-metrics slow"

section "4. Core observability stack"
kubectl apply -f observability/prometheus/prometheus.yaml
kubectl apply -f observability/loki/loki.yaml
kubectl apply -f observability/tempo/tempo.yaml

info "Waiting for Prometheus (Alloy remote_write target)..."
wait_ready_kind deployment prometheus observability 180

info "Loki and Tempo starting in background..."
kubectl rollout status deployment/loki  -n observability --timeout=120s 2>/dev/null &
kubectl rollout status deployment/tempo -n observability --timeout=120s 2>/dev/null &

section "5. Alloy (trace + log collector)"
kubectl apply -f observability/alloy/alloy.yaml

info "Waiting for Alloy DaemonSet (up to 390s)..."
alloy_ready=false
for i in $(seq 1 78); do
  desired=$(kubectl get daemonset alloy -n observability \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  ready=$(kubectl get daemonset alloy -n observability \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  if [[ "${ready:-0}" -ge 1 && "${ready:-0}" -ge "${desired:-1}" ]]; then
    alloy_ready=true
    break
  fi
  sleep 5
done
$alloy_ready && info "Alloy ready ✓" || \
  warn "Alloy not fully ready — check: kubectl logs -n observability daemonset/alloy --tail=40"

section "6. Grafana"
kubectl apply -f observability/grafana/grafana.yaml
wait_ready_kind deployment grafana observability 180 || \
  warn "Grafana still pulling image — boutique will deploy now."

wait || true

section "7. Local registry (patched frontend image)"
if command -v docker &>/dev/null; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^local-registry$"; then
    info "Local registry already running ✓"
  else
    info "Starting local registry on :5001..."
    docker run -d -p 5001:5000 --name local-registry registry:2 2>/dev/null || \
      docker start local-registry 2>/dev/null || true
    sleep 2
  fi

  if docker manifest inspect localhost:5001/boutique-frontend:arm64-v1 &>/dev/null 2>&1; then
    info "Patched frontend image verified in registry ✓"
  else
    warn "Patched frontend image NOT found in registry."
    warn "Frontend pod will fail with ImagePullBackOff until this is resolved."
    warn ""
    warn "Rebuild:"
    warn "  cd /tmp/boutique-patch"
    warn "  docker buildx build --platform linux/arm64 \\"
    warn "    --build-arg TARGETARCH=arm64 --build-arg TARGETOS=linux \\"
    warn "    --load -t boutique-frontend:arm64-v1 src/frontend/"
    warn "  docker tag boutique-frontend:arm64-v1 localhost:5001/boutique-frontend:arm64-v1"
    warn "  docker push localhost:5001/boutique-frontend:arm64-v1"
    warn ""
    warn "Continuing — other services will come up normally."
  fi
else
  warn "docker not found — skipping local registry check"
fi

section "8. Boutique application"
kubectl apply -f boutique/boutique.yaml

info "Waiting for Redis..."
wait_ready_kind deployment redis boutique 60 || warn "Redis slow to start"

info "Cartservice starting in background (.NET JIT — non-blocking)..."
kubectl rollout status deployment/cartservice -n boutique --timeout=150s 2>/dev/null &
CART_PID=$!

info "Waiting for productcatalogservice..."
wait_ready_kind deployment productcatalogservice boutique 90 || \
  warn "productcatalogservice slow to start"

info "Waiting for frontend (includes minReadySeconds=30 gate — up to 150s)..."
wait_ready_kind deployment frontend boutique 150 || warn "Frontend slow to start"

for svc in emailservice recommendationservice shippingservice \
           paymentservice currencyservice adservice checkoutservice; do
  kubectl rollout status "deployment/$svc" -n boutique --timeout=180s 2>/dev/null &
done
wait || true
info "All boutique services scheduled ✓"

wait $CART_PID 2>/dev/null || warn "Cartservice may still be pulling image — HPA will retry"

section "9. HPA"
if kubectl top nodes &>/dev/null 2>&1; then
  info "metrics-server is returning data — applying HPA"
  kubectl apply -f boutique/hpa.yaml
  info "HPA applied ✓"
else
  warn "metrics-server not returning data yet — applying HPA anyway"
  kubectl apply -f boutique/hpa.yaml
  warn "Run 'kubectl get hpa -n boutique' in 60s to verify HPA has CPU metrics"
fi

section "10. Port-forwards (ClusterIP services only)"
# [v6] Only port-forward ClusterIP services.
# Frontend :8080, Grafana :3000, Prometheus :9090 are LoadBalancer — Docker
# Desktop exposes them directly. Port-forwarding them causes bind conflicts.
pkill -f "kubectl port-forward" 2>/dev/null || true
[[ -f "$PF_PID_FILE" ]] && rm "$PF_PID_FILE"
touch "$PF_PID_FILE"
for pf in "${PF_DEFS[@]}"; do
  read -r ns svc lp rp url <<< "$pf"
  start_port_forward "$ns" "$svc" "$lp" "$rp" "$url"
done

section "11. Warm gate + Final status"

WORKING_URL=$(bash "$SCRIPT_DIR/find-url.sh" --export 2>/dev/null || echo "http://localhost:8080")

echo ""
info "Running end-to-end warm gate — stack is not declared ready until / returns real content..."
gate_start=$(date +%s)
wait_warm_gate "$WORKING_URL" 180
gate_end=$(date +%s)
gate_elapsed=$((gate_end - gate_start))

echo ""
kubectl get pods -n observability 2>/dev/null
echo ""
kubectl get pods -n boutique 2>/dev/null
echo ""
kubectl get hpa -n boutique 2>/dev/null

# Show actual LoadBalancer IPs for reference
GRAFANA_IP=$(kubectl get svc grafana -n observability \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "172.18.0.x")
PROM_IP=$(kubectl get svc prometheus -n observability \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "172.18.0.x")

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN} STACK IS UP AND WARM (gate took ${gate_elapsed}s)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Boutique:    $WORKING_URL            (LoadBalancer)"
echo "  Grafana:     http://${GRAFANA_IP}:3000    admin/admin  (LoadBalancer)"
echo "  Prometheus:  http://${PROM_IP}:9090   (LoadBalancer)"
echo ""
echo "  Alloy UI:    http://localhost:12345   (port-forward)"
echo "  Tempo:       http://localhost:3200    (port-forward)"
echo "  Loki:        http://localhost:3100    (port-forward)"
echo ""
echo "  Smoke test:  k6 run --env BASE_URL=$WORKING_URL scripts/load-test_10vusers.js"
echo "  100 VU:      k6 run --env BASE_URL=$WORKING_URL scripts/load-test_100vusers.js"
echo "  1000 VU:     k6 run --env BASE_URL=$WORKING_URL scripts/load-test_1000vusers.js"
echo "  Verify:      bash scripts/verify-stability.sh --short"
echo "  HPA watch:   bash scripts/manage.sh hpa-watch"
echo "  Full debug:  bash scripts/manage.sh debug"
echo "  Health:      bash scripts/manage.sh doctor"
echo ""
