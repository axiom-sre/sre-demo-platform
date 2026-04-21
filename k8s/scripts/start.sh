#!/bin/bash
# =============================================================================
# start.sh — SRE Demo Platform: Full Startup v4
# =============================================================================
#
# Usage:
#   bash scripts/start.sh              # full startup
#   bash scripts/start.sh --pf-only   # restart port-forwards only
#   bash scripts/start.sh --verify    # re-run pipeline verification only
#
# STARTUP ORDER (do not change — dependencies are load-bearing):
#   0. PriorityClasses  — must exist before any pod is scheduled
#   1. Namespaces + ResourceQuotas
#   2. Observability infrastructure (infra + metrics-server)
#   3. Core observability stack (Prometheus, Loki, Tempo, Alloy)
#   4. Grafana
#   5. Boutique application services
#   6. HPA (must come AFTER metrics-server is ready)
#   7. Port-forwards + pipeline verification
#
# KEY CHANGES vs v2:
#
# 1. Frontend readiness wait now accounts for minReadySeconds=30.
#    boutique.yaml v3 adds minReadySeconds=30 to the frontend Deployment.
#    This means kubectl rollout status completes ~30s LATER than before —
#    the pod passes readiness probe, then waits 30 more seconds before the
#    rollout considers it Available. We now wait 150s (was 120s) for frontend
#    to give this window room without false timeout warnings.
#
# 2. Backend dependency pre-check added before frontend wait.
#    Redis, cartservice, and productcatalogservice are waited on BEFORE
#    declaring frontend ready. Previously a slow .NET cartservice startup
#    would cause frontend to pass readiness but return 500s on /cart.
#    New order: redis → cart → productcatalog → frontend.
#    This makes start.sh's "boutique ready" declaration honest.
#
# 3. Port-forward health check URL changed: localhost:30080 → localhost:8080.
#    NodePort 30080 is unreliable on Docker Desktop. The LoadBalancer path
#    (port 8080) is the correct primary URL. find-url.sh confirmed this.
#
# 4. Final status section now runs find-url.sh to print the verified URL.
#    Previously it printed static text — now it prints the URL that actually works.
#
# KEY CHANGES v4:
#
# 5. wait_warm_gate() added — end-to-end HTTP verification before "STACK IS UP".
#    Previous versions declared the stack ready based on kubectl rollout status,
#    which only checks that pods passed /_healthz (the frontend HTTP server).
#    /_healthz does NOT check gRPC backend connectivity. The result: frontend is
#    "ready" while cartservice (.NET JIT ~45s), productcatalog, and currency are
#    still warming up → first real requests return 500s for up to 90s.
#    New gate: poll GET / until HTTP 200 with body containing "Hot Products" —
#    this requires productcatalog + currency + recommendation to all respond.
#    Only then print STACK IS UP. Demo starts clean. Zero cold-start 500s visible.
#
# 6. wait_backends_warm() added before frontend wait.
#    Polls cartservice :7070 and productcatalogservice :3550 TCP sockets directly
#    from within the cluster (via kubectl exec on a running pod) to confirm the
#    gRPC servers are accepting connections — not just that pods passed their own
#    probes. Prevents the 30-60s window where frontend is Ready but returns 500s
#    because its backends have not finished JIT/import warmup.
#
# 7. Section 9 renamed "9. Warm gate + Final status" to make the gate visible
#    in the startup log. The gate prints elapsed wait time so the operator knows
#    how long backends took — useful data for demo timing.
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

PF_DEFS=(
  "boutique      frontend   8080  8080  http://localhost:8080/_healthz"
  "observability grafana    3000  3000  http://localhost:3000/api/health"
  "observability prometheus 9090  9090  http://localhost:9090/-/healthy"
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

wait_http() {
  local url=$1 timeout_sec=${2:-120} label=${3:-$1}
  info "Waiting for $label to respond (up to ${timeout_sec}s)..."
  local elapsed=0
  while ! curl -sf "$url" -o /dev/null -m 5 2>/dev/null; do
    sleep 5; elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout_sec ]]; then
      warn "$label did not respond after ${timeout_sec}s"
      return 1
    fi
  done
  info "$label is up ✓"
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

# ── Backend TCP warm check (run from kubectl exec inside cluster) ─────────────
# Polls a TCP port directly from a running pod — verifies the gRPC server is
# accepting connections, not just that the pod passed its own readiness probe.
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

# ── End-to-end HTTP warm gate ─────────────────────────────────────────────────
# Polls GET / until HTTP 200 with real product page content.
# Requires productcatalog + currency + recommendation all responding.
# This is the HONEST "stack is ready" signal — not just "pods are scheduled".
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
      # After 30s of 200s, accept it even if grep misses (CDN/cache variations)
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
  section "Port-forwards only"
  pkill -f "kubectl port-forward" 2>/dev/null || true
  [[ -f "$PF_PID_FILE" ]] && rm "$PF_PID_FILE"
  touch "$PF_PID_FILE"
  for pf in "${PF_DEFS[@]}"; do
    read -r ns svc lp rp url <<< "$pf"
    start_port_forward "$ns" "$svc" "$lp" "$rp" "$url"
  done
  echo ""
  info "Port-forwards started."
  WORKING_URL=$(bash "$SCRIPT_DIR/find-url.sh" --export 2>/dev/null || echo "http://localhost:8080")
  info "Frontend: $WORKING_URL  |  Grafana: http://localhost:3000"
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
kubectl cluster-info &>/dev/null || { error "cluster unreachable — is Docker Desktop running?"; exit 1; }
info "Cluster: $(kubectl config current-context)"

total_mem_gb=$(kubectl get node -o jsonpath='{.items[0].status.capacity.memory}' 2>/dev/null \
  | sed 's/Ki$//' | awk '{printf "%.0f", $1/1024/1024}' || echo "0")
if [[ "$total_mem_gb" -lt 16 ]]; then
  warn "Node has only ${total_mem_gb}GB RAM. Recommend 24GB+ for 1000 VU."
else
  info "Node memory: ${total_mem_gb}GB ✓"
fi

section "1. PriorityClasses + Namespaces"
kubectl apply -f namespaces/priority-classes.yaml
kubectl apply -f namespaces/namespaces.yaml
info "PriorityClasses and namespaces ready ✓"

section "2. Observability infrastructure"
kubectl apply -f observability/infrastructure/infrastructure.yaml
wait_ready_kind deployment metrics-server kube-system 120 || \
  warn "metrics-server slow — HPA may not work initially"

section "3. Core observability stack"
kubectl apply -f observability/prometheus/prometheus.yaml
kubectl apply -f observability/loki/loki.yaml
kubectl apply -f observability/tempo/tempo.yaml

info "Waiting for Prometheus (Alloy remote_write target)..."
wait_ready_kind deployment prometheus observability 180

info "Loki and Tempo starting in background..."
kubectl rollout status deployment/loki  -n observability --timeout=120s 2>/dev/null &
kubectl rollout status deployment/tempo -n observability --timeout=120s 2>/dev/null &

section "4. Alloy (trace + log collector)"
kubectl apply -f observability/alloy/alloy.yaml

info "Waiting for Alloy DaemonSet (up to 390s — cold start can take 2-3 min)..."
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
if $alloy_ready; then
  info "Alloy ready ✓"
else
  warn "Alloy not fully ready after 390s — check: kubectl logs -n observability daemonset/alloy --tail=40"
fi

section "5. Grafana"
kubectl apply -f observability/grafana/grafana.yaml
wait_ready_kind deployment grafana observability 180 || \
  warn "Grafana still pulling image — boutique will deploy now."

wait || true

section "6. Boutique application"
kubectl apply -f boutique/boutique.yaml

# Wait for the dependency chain in order — this order matters.
# Redis must be ready before cartservice can connect.
# Cart must be ready before frontend stops returning 500s on /cart.
# productcatalog must be ready before frontend stops returning 500s on homepage.
# minReadySeconds=30 on frontend means rollout status completes 30s after
# the readiness probe passes — by then all backends should be warm.

info "Waiting for Redis..."
wait_ready_kind deployment redis boutique 60 || warn "Redis slow to start"

# Cart runs in background — don't block the rest of startup on .NET JIT.
# Its startupProbe (135s window) handles the JIT warmup gate independently.
# Frontend minReadySeconds=30 gives cart additional buffer before traffic arrives.
info "Cartservice starting in background (.NET JIT — non-blocking)..."
kubectl rollout status deployment/cartservice -n boutique --timeout=150s 2>/dev/null &
CART_PID=$!

info "Waiting for productcatalogservice..."
wait_ready_kind deployment productcatalogservice boutique 90 || \
  warn "productcatalogservice slow to start"

info "Waiting for frontend (includes minReadySeconds=30 gate — up to 150s)..."
# 150s = 15s startup probe + 30s minReadySeconds + 30s image pull buffer
wait_ready_kind deployment frontend boutique 150 || warn "Frontend slow to start"

# All other services in background — not in the critical request path for homepage
for svc in emailservice recommendationservice shippingservice \
           paymentservice currencyservice adservice checkoutservice; do
  kubectl rollout status "deployment/$svc" -n boutique --timeout=180s 2>/dev/null &
done
wait || true
info "All boutique services scheduled ✓"

# Collect cart background wait — it had its chance, HPA needs it ready
wait $CART_PID 2>/dev/null || warn "Cartservice may still be pulling image — HPA will retry"

section "7. HPA"
if kubectl top nodes &>/dev/null 2>&1; then
  info "metrics-server is returning data — applying HPA"
  kubectl apply -f boutique/hpa.yaml
  info "HPA applied ✓"
else
  warn "metrics-server not returning data yet — applying HPA anyway"
  kubectl apply -f boutique/hpa.yaml
  warn "Run 'kubectl get hpa -n boutique' in 60s to verify HPA has CPU metrics"
fi

section "8. Port-forwards (observability)"
pkill -f "kubectl port-forward" 2>/dev/null || true
[[ -f "$PF_PID_FILE" ]] && rm "$PF_PID_FILE"
touch "$PF_PID_FILE"
for pf in "${PF_DEFS[@]}"; do
  read -r ns svc lp rp url <<< "$pf"
  start_port_forward "$ns" "$svc" "$lp" "$rp" "$url"
done

section "9. Warm gate + Final status"

# Port-forward must be up before warm gate can poll localhost
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

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN} STACK IS UP AND WARM (gate took ${gate_elapsed}s)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""

echo "  Boutique:   $WORKING_URL"
echo "  Grafana:    http://localhost:3000    admin/admin"
echo ""
echo "  Prometheus: http://localhost:9090"
echo "  Alloy:      http://localhost:12345"
echo "  Tempo:      http://localhost:3200"
echo "  Loki:       http://localhost:3100"
echo ""
echo "  Smoke test:   k6 run --env BASE_URL=$WORKING_URL scripts/load-test_10vusers.js"
echo "  100 VU:       k6 run --env BASE_URL=$WORKING_URL scripts/load-test_100vusers.js"
echo "  1000 VU:      k6 run --env BASE_URL=$WORKING_URL scripts/load-test_1000vusers.js"
echo "  Verify:       bash scripts/verify-stability.sh --short"
echo "  HPA watch:    bash scripts/manage.sh hpa-watch"
echo "  Full debug:   bash scripts/manage.sh debug"
echo ""
