#!/bin/bash
# =============================================================================
# manage.sh — SRE Demo Platform: Operations (Holy Grail Edition)
# =============================================================================
#
# Usage (run from repo root):
#   bash scripts/manage.sh stop              graceful teardown (PVCs preserved)
#   bash scripts/manage.sh nuke              full reset — deletes all data
#   bash scripts/manage.sh status            pod + HPA + PVC + ResourceQuota status
#   bash scripts/manage.sh debug             full diagnostic dump
#   bash scripts/manage.sh logs <svc> [ns]   tail logs for a service
#   bash scripts/manage.sh verify            check metrics + log pipelines
#   bash scripts/manage.sh budget            node CPU/memory budget summary
#   bash scripts/manage.sh cart-debug        deep-dive cartservice diagnostics
#   bash scripts/manage.sh hpa-watch         live HPA scaling monitor (refreshes every 5s)
#   bash scripts/manage.sh restart <svc> [ns] rolling restart a deployment
#   bash scripts/manage.sh top               kubectl top pods for both namespaces
#
# KEY CHANGES vs previous version:
#   1. stop: now deletes resources in reverse dependency order — alloy first
#      (stops new spans), then boutique, then observability. This prevents
#      the situation where Tempo gets deleted while Alloy is still sending
#      spans, causing a flood of UNAVAILABLE errors in the WAL queue.
#   2. nuke: now also deletes PriorityClasses (they're cluster-scoped and
#      were previously orphaned after nuke, causing "already exists" errors
#      on next start.sh run).
#   3. logs: added --previous flag support for post-crash log inspection.
#      `manage.sh logs cartservice boutique --previous` shows the logs from
#      the crashed container, not the new replacement.
#   4. debug: added ResourceQuota usage, cartservice-specific OOM check,
#      and HPA TARGETS column (shows actual vs target CPU utilization).
#   5. New: budget — prints node CPU and memory request/limit totals by
#      namespace so you can see if you're approaching node saturation.
#   6. New: cart-debug — one-stop cartservice failure diagnosis:
#      Redis connection count, .NET GC env vars, recent OOM events,
#      HPA current/desired, pod resource usage.
#   7. New: hpa-watch — watch-style HPA status that refreshes every 5s,
#      showing TARGETS (current% / threshold%) alongside replica count.
#   8. New: restart — rolling restart a specific deployment without stop/start.
#   9. New: top — kubectl top pods for both namespaces side-by-side.
# =============================================================================

set -euo pipefail

CMD="${1:-status}"
OBS=observability
APP=boutique

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}▶${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC} $*"; }
header()  { echo -e "\n${BOLD}── $* ──────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PF_PID_FILE="${REPO_ROOT}/.pf-pids"

# Workload kind lookup — alloy is a DaemonSet, everything else is a Deployment
get_kind_for_svc() {
  case "$1" in
    alloy) echo "daemonset" ;;
    node-exporter) echo "daemonset" ;;
    *)     echo "deployment" ;;
  esac
}

# ── stop ──────────────────────────────────────────────────────────────────────
# Delete in reverse dependency order so no component tries to write to an
# already-deleted backend. Alloy → boutique → observability backends.
stop() {
  info "Stopping port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  [[ -f "$PF_PID_FILE" ]] && rm -f "$PF_PID_FILE"

  info "Stopping Alloy (pause trace/log ingestion first)..."
  kubectl delete -f "${REPO_ROOT}/observability/alloy/alloy.yaml" \
    --ignore-not-found 2>/dev/null || true

  info "Stopping boutique (stop traffic source)..."
  kubectl delete -f "${REPO_ROOT}/boutique/hpa.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/boutique/boutique.yaml" \
    --ignore-not-found 2>/dev/null || true

  info "Stopping observability backends (PVCs preserved)..."
  kubectl delete -f "${REPO_ROOT}/observability/grafana/grafana.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/observability/tempo/tempo.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/observability/loki/loki.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/observability/prometheus/prometheus.yaml" \
    --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${REPO_ROOT}/observability/infrastructure/infrastructure.yaml" \
    --ignore-not-found 2>/dev/null || true

  echo ""
  info "Stack stopped. PVCs preserved (metric + trace + log history intact)."
  info "Restart:    bash scripts/start.sh"
  info "Wipe data:  bash scripts/manage.sh nuke"
}

# ── nuke ──────────────────────────────────────────────────────────────────────
nuke() {
  warn "This will DELETE namespaces '$OBS' and '$APP' and all PriorityClasses."
  warn "All Prometheus metrics, Loki logs, and Tempo traces will be lost."
  read -r -p "  Are you sure? (y/N) " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

  info "Stopping port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  [[ -f "$PF_PID_FILE" ]] && rm -f "$PF_PID_FILE"

  info "Deleting namespaces (30-60s)..."
  kubectl delete namespace "$OBS" --ignore-not-found
  kubectl delete namespace "$APP" --ignore-not-found

  info "Deleting PriorityClasses (cluster-scoped — must clean up manually)..."
  kubectl delete priorityclass boutique-high boutique-standard boutique-background \
    observability-high --ignore-not-found 2>/dev/null || true

  echo ""
  info "Clean slate. Run 'bash scripts/start.sh' to redeploy everything."
}

# ── status ────────────────────────────────────────────────────────────────────
status() {
  header "Observability pods"
  kubectl get pods -n "$OBS" -o wide 2>/dev/null || warn "Namespace $OBS not found"

  header "Boutique pods"
  kubectl get pods -n "$APP" -o wide 2>/dev/null || warn "Namespace $APP not found"

  header "HPA"
  kubectl get hpa -n "$APP" 2>/dev/null || warn "No HPA in $APP"

  header "PVCs"
  kubectl get pvc -n "$OBS" 2>/dev/null || true
  kubectl get pvc -n "$APP" 2>/dev/null || true

  header "ResourceQuota usage"
  kubectl describe resourcequota -n "$OBS" 2>/dev/null | grep -E "(Resource|requests|limits|pods)" | head -20 || true
  echo ""
  kubectl describe resourcequota -n "$APP" 2>/dev/null | grep -E "(Resource|requests|limits|pods)" | head -20 || true
}

# ── debug ─────────────────────────────────────────────────────────────────────
debug() {
  echo -e "${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${BOLD} DEBUG REPORT — $(date)${NC}"
  echo -e "${BOLD}════════════════════════════════════════════${NC}"

  header "Node resources"
  kubectl top nodes 2>/dev/null || warn "metrics-server not ready yet"

  header "Pod status — observability"
  kubectl get pods -n "$OBS" -o wide 2>/dev/null

  header "Pod status — boutique"
  kubectl get pods -n "$APP" -o wide 2>/dev/null

  header "HPA (with TARGETS — shows actual vs threshold CPU)"
  kubectl get hpa -n "$APP" 2>/dev/null || true

  header "ResourceQuota usage — boutique"
  kubectl describe resourcequota boutique-quota -n "$APP" 2>/dev/null || true

  header "ResourceQuota usage — observability"
  kubectl describe resourcequota observability-quota -n "$OBS" 2>/dev/null || true

  header "PriorityClasses"
  kubectl get priorityclass 2>/dev/null | grep -E "(NAME|boutique|observability)" || true

  header "Warning events — observability (last 15)"
  kubectl get events -n "$OBS" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true

  header "Warning events — boutique (last 15)"
  kubectl get events -n "$APP" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true

  header "Alloy logs (last 40)"
  kubectl logs -n "$OBS" daemonset/alloy --tail=40 2>/dev/null || warn "Alloy not running"

  header "Prometheus logs (last 20)"
  kubectl logs -n "$OBS" deployment/prometheus --tail=20 2>/dev/null || true

  header "Loki logs (last 20)"
  kubectl logs -n "$OBS" deployment/loki --tail=20 2>/dev/null || true

  header "Tempo logs (last 20)"
  kubectl logs -n "$OBS" deployment/tempo --tail=20 2>/dev/null || true

  header "Grafana logs (last 20)"
  kubectl logs -n "$OBS" deployment/grafana --tail=20 2>/dev/null || true

  header "CartService logs (last 30) — current pod"
  kubectl logs -n "$APP" deployment/cartservice --tail=30 2>/dev/null || warn "CartService not running"

  header "Frontend logs (last 20)"
  kubectl logs -n "$APP" deployment/frontend --tail=20 2>/dev/null || warn "Frontend not running"

  header "PVCs"
  kubectl get pvc -n "$OBS" 2>/dev/null || true
  kubectl get pvc -n "$APP" 2>/dev/null || true

  header "Services"
  kubectl get svc -n "$OBS" 2>/dev/null || true
  kubectl get svc -n "$APP" 2>/dev/null || true
}

# ── logs ──────────────────────────────────────────────────────────────────────
# Usage: manage.sh logs <svc> [namespace] [--previous]
# Defaults: svc=alloy, namespace=observability
# --previous: show logs from the last crashed container (post-OOM debug)
logs() {
  local svc="${2:-alloy}"
  local ns="${3:-$OBS}"
  local previous_flag=""
  # Support --previous anywhere in args
  for arg in "$@"; do
    [[ "$arg" == "--previous" ]] && previous_flag="--previous"
  done
  local kind
  kind=$(get_kind_for_svc "$svc")
  if [[ -n "$previous_flag" ]]; then
    info "Showing PREVIOUS (crashed) container logs for $kind/$svc in $ns..."
    kubectl logs -n "$ns" "$kind/$svc" --previous --tail=100 2>/dev/null \
      || warn "No previous container found — pod may not have restarted yet"
  else
    info "Tailing $kind/$svc in $ns (Ctrl+C to stop)..."
    kubectl logs -n "$ns" "$kind/$svc" -f --tail=50
  fi
}

# ── verify ────────────────────────────────────────────────────────────────────
verify() {
  echo ""
  info "Checking golden signal metrics..."

  local pf_started=false
  local pf_pid=0
  if ! curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 3 2>/dev/null; then
    kubectl port-forward -n "$OBS" svc/prometheus 9090:9090 &>/tmp/pf-verify-prom.log &
    pf_pid=$!
    sleep 3
    pf_started=true
  fi

  local BASE="http://localhost:9090/api/v1/query"
  _check() {
    local label=$1 query=$2
    local result
    result=$(curl -sg "$BASE" --data-urlencode "query=$query" 2>/dev/null | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('data', {}).get('result', [])
print('HAS DATA') if r else print('NO DATA')
" 2>/dev/null || echo "UNREACHABLE")
    if [[ "$result" == "HAS DATA" ]]; then
      printf "  ${GREEN}✓${NC} %-48s HAS DATA\n" "$label"
    elif [[ "$result" == "NO DATA" ]]; then
      printf "  ${YELLOW}~${NC} %-48s NO DATA (send traffic first)\n" "$label"
    else
      printf "  ${RED}✗${NC} %-48s UNREACHABLE\n" "$label"
    fi
  }

  _check "spanmetrics latency bucket"   'count(traces_spanmetrics_latency_bucket)'
  _check "spanmetrics calls total"      'count(traces_spanmetrics_calls_total)'
  _check "p95 latency (all services)"   'histogram_quantile(0.95,sum by(le,service)(rate(traces_spanmetrics_latency_bucket[5m])))'
  _check "p99 latency (all services)"   'histogram_quantile(0.99,sum by(le,service)(rate(traces_spanmetrics_latency_bucket[5m])))'
  _check "request rate by service"      'sum by(service)(rate(traces_spanmetrics_calls_total[5m]))'
  _check "service graph edges"          'count(traces_service_graph_request_total)'
  _check "kube-state-metrics HPA data"  'kube_horizontalpodautoscaler_status_current_replicas'
  _check "node CPU usage"               'instance:node_cpu_utilisation:rate5m'
  _check "Alloy OTLP spans received"    'alloy_otelcol_receiver_accepted_spans_total'

  $pf_started && kill "$pf_pid" 2>/dev/null; pf_started=false

  echo ""
  info "Checking Loki log pipeline..."
  local loki_up=false
  local loki_pid=0
  if ! curl -sf "http://localhost:3100/ready" -o /dev/null -m 3 2>/dev/null; then
    kubectl port-forward -n "$OBS" svc/loki 3100:3100 &>/tmp/pf-verify-loki.log &
    loki_pid=$!
    sleep 3
    loki_up=true
  fi

  local labels
  labels=$(curl -sg "http://localhost:3100/loki/api/v1/labels" 2>/dev/null | \
    python3 -c "
import sys, json
d = json.load(sys.stdin)
l = d.get('data', [])
print('OK: ' + ', '.join(sorted(l))) if l else print('NO LABELS')
" 2>/dev/null || echo "UNREACHABLE")

  if [[ "$labels" == OK* ]]; then
    printf "  ${GREEN}✓${NC} Loki labels: %s\n" "${labels#OK: }"
  elif [[ "$labels" == "NO LABELS" ]]; then
    printf "  ${YELLOW}~${NC} Loki: ready but no labels yet (Alloy still discovering pods)\n"
  else
    printf "  ${RED}✗${NC} Loki: unreachable — check 'manage.sh logs loki'\n"
  fi

  $loki_up && kill "$loki_pid" 2>/dev/null || true
  echo ""
}

# ── budget ────────────────────────────────────────────────────────────────────
# Prints a summary of CPU and memory requests vs node capacity.
# Helps you see at a glance if you're approaching scheduling limits.
budget() {
  header "Node capacity"
  kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory' \
    2>/dev/null

  header "CPU + Memory requests by namespace"
  for ns in "$APP" "$OBS" kube-system; do
    echo ""
    echo -e "  ${BOLD}$ns${NC}"
    kubectl get pods -n "$ns" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
cpu_req = mem_req = cpu_lim = mem_lim = 0
def parse_cpu(v):
    if not v: return 0
    if v.endswith('m'): return int(v[:-1])
    return int(float(v) * 1000)
def parse_mem(v):
    if not v: return 0
    if v.endswith('Mi'): return int(v[:-2])
    if v.endswith('Gi'): return int(v[:-2]) * 1024
    if v.endswith('Ki'): return int(v[:-2]) // 1024
    return int(v) // (1024*1024)
for pod in data['items']:
    for c in pod['spec'].get('containers', []):
        r = c.get('resources', {})
        cpu_req += parse_cpu(r.get('requests', {}).get('cpu'))
        mem_req += parse_mem(r.get('requests', {}).get('memory'))
        cpu_lim += parse_cpu(r.get('limits', {}).get('cpu'))
        mem_lim += parse_mem(r.get('limits', {}).get('memory'))
print(f'  requests: cpu={cpu_req}m  mem={mem_req}Mi')
print(f'  limits:   cpu={cpu_lim}m  mem={mem_lim}Mi')
" 2>/dev/null || echo "  (no pods or namespace not found)"
  done

  echo ""
  header "HPA scale-out capacity remaining"
  kubectl get hpa -n "$APP" \
    -o custom-columns='HPA:.metadata.name,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,MAX:.spec.maxReplicas,TARGETS:.status.conditions[0].message' \
    2>/dev/null || true
}

# ── cart-debug ─────────────────────────────────────────────────────────────────
# One-stop cartservice failure diagnosis. Run this when cart is crash-looping.
cart_debug() {
  echo -e "${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${BOLD} CARTSERVICE DEEP DIAGNOSTIC — $(date)${NC}"
  echo -e "${BOLD}════════════════════════════════════════════${NC}"

  header "CartService pods"
  kubectl get pods -n "$APP" -l app=cartservice -o wide 2>/dev/null

  header "CartService resource usage (kubectl top)"
  kubectl top pods -n "$APP" -l app=cartservice 2>/dev/null \
    || warn "metrics-server not ready"

  header "CartService HPA"
  kubectl get hpa cartservice -n "$APP" 2>/dev/null || warn "No cartservice HPA found"
  kubectl describe hpa cartservice -n "$APP" 2>/dev/null | grep -E "(Events|Conditions|Current|Desired)" || true

  header "CartService environment (.NET GC vars)"
  kubectl get pods -n "$APP" -l app=cartservice -o jsonpath='{range .items[0].spec.containers[*]}{range .env[*]}{.name}{"="}{.value}{"\n"}{end}{end}' \
    2>/dev/null | grep -E "(DOTNET|GC|REDIS)" || warn "Could not read env — pod may not be running"

  header "CartService logs — current pod (last 50)"
  kubectl logs -n "$APP" deployment/cartservice --tail=50 2>/dev/null \
    || warn "No running cartservice pod"

  header "CartService logs — PREVIOUS crashed pod (if any)"
  kubectl logs -n "$APP" deployment/cartservice --previous --tail=50 2>/dev/null \
    || info "No previous container (no recent crash, or pod not yet restarted)"

  header "Redis pod status"
  kubectl get pods -n "$APP" -l app=redis -o wide 2>/dev/null
  kubectl top pods -n "$APP" -l app=redis 2>/dev/null || true

  header "Redis logs (last 30)"
  kubectl logs -n "$APP" deployment/redis --tail=30 2>/dev/null || warn "Redis not running"

  header "OOM events — boutique namespace (last 10 min)"
  kubectl get events -n "$APP" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | \
    grep -iE "(OOMKill|oom|Evict|BackOff)" | tail -20 || info "No OOM/eviction events"

  header "Recent Warning events — boutique"
  kubectl get events -n "$APP" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
}

# ── hpa-watch ─────────────────────────────────────────────────────────────────
# Live HPA monitor — refreshes every 5s. Shows TARGETS (actual/threshold).
# Press Ctrl+C to exit.
hpa_watch() {
  info "Live HPA monitor — refreshing every 5s (Ctrl+C to stop)"
  echo ""
  while true; do
    clear
    echo -e "${BOLD}  HPA LIVE — $(date '+%H:%M:%S')${NC}"
    echo ""
    kubectl get hpa -n "$APP" 2>/dev/null || true
    echo ""
    echo -e "${BOLD}  Pod counts:${NC}"
    kubectl get pods -n "$APP" --no-headers 2>/dev/null | \
      awk '{split($1,a,"-"); svc=a[1]; for(i=2;i<=length(a)-2;i++) svc=svc"-"a[i]; count[svc]++} END {for(s in count) printf "    %-30s %d pods\n", s, count[s]}' | sort
    echo ""
    echo -e "${BOLD}  Node CPU (top nodes):${NC}"
    kubectl top nodes 2>/dev/null | tail -2 || echo "  (metrics-server not ready)"
    sleep 5
  done
}

# ── restart ───────────────────────────────────────────────────────────────────
# Rolling restart a deployment without full stop/start cycle.
# Usage: manage.sh restart <svc> [namespace]
restart_svc() {
  local svc="${2:-}"
  local ns="${3:-$APP}"
  if [[ -z "$svc" ]]; then
    error "Usage: manage.sh restart <service-name> [namespace]"
    error "Example: manage.sh restart cartservice boutique"
    exit 1
  fi
  local kind
  kind=$(get_kind_for_svc "$svc")
  info "Rolling restart of $kind/$svc in namespace $ns..."
  kubectl rollout restart "$kind/$svc" -n "$ns"
  info "Waiting for rollout to complete..."
  kubectl rollout status "$kind/$svc" -n "$ns" --timeout=120s
  info "Restart complete ✓"
}

# ── top ───────────────────────────────────────────────────────────────────────
top_pods() {
  header "Top pods — boutique"
  kubectl top pods -n "$APP" --sort-by=cpu 2>/dev/null || warn "metrics-server not ready"

  header "Top pods — observability"
  kubectl top pods -n "$OBS" --sort-by=cpu 2>/dev/null || true

  header "Top nodes"
  kubectl top nodes 2>/dev/null || true
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
  stop)        stop ;;
  nuke)        nuke ;;
  status)      status ;;
  debug)       debug ;;
  logs)        logs "$@" ;;
  verify)      verify ;;
  budget)      budget ;;
  cart-debug)  cart_debug ;;
  hpa-watch)   hpa_watch ;;
  restart)     restart_svc "$@" ;;
  top)         top_pods ;;
  *)
    echo ""
    echo -e "${BOLD}Usage: bash scripts/manage.sh <command>${NC}"
    echo ""
    echo "  stop                    graceful teardown (PVCs preserved)"
    echo "  nuke                    full reset — deletes all data + PriorityClasses"
    echo "  status                  pods + HPA + PVCs + ResourceQuota usage"
    echo "  debug                   full diagnostic dump (all logs + events)"
    echo "  logs <svc> [ns] [--previous]"
    echo "                          tail service logs; --previous for post-crash"
    echo "  verify                  check metrics, traces, and log pipelines"
    echo "  budget                  node CPU/memory budget summary"
    echo "  cart-debug              deep-dive cartservice failure diagnosis"
    echo "  hpa-watch               live HPA scaling monitor (refreshes 5s)"
    echo "  restart <svc> [ns]      rolling restart a deployment"
    echo "  top                     kubectl top pods for both namespaces"
    echo ""
    echo "Startup:    bash scripts/start.sh"
    echo "Stability:  bash scripts/verify-stability.sh [--short|--no-k6]"
    echo ""
    exit 1
    ;;
esac
