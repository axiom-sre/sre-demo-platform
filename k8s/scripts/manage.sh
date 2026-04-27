#!/bin/bash
# =============================================================================
# manage.sh — SRE Demo Platform: Operations (Holy Grail Edition v2)
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
#   bash scripts/manage.sh suspend           scale all to 0, free RAM (keeps PVCs/config)
#   bash scripts/manage.sh resume            restore replicas from suspend (fast)
#   bash scripts/manage.sh grafana-export    export Grafana UI edits to JSON files
#   bash scripts/manage.sh doctor            health check everything in one command
#
# KEY CHANGES vs v1:
#
# [v2] doctor() PVC check: added loki-pvc.
#      loki.yaml v2 added a PVC for Loki (/var/loki) so log data survives
#      pod restarts. Previous doctor() only checked grafana-pvc, prometheus-pvc,
#      tempo-pvc — loki-pvc was silently skipped. Now all 4 are checked.
#
# [v2] doctor() port-forward checks: removed frontend :8080, grafana :3000,
#      prometheus :9090. These are LoadBalancer services — Docker Desktop
#      exposes them via the VM network bridge directly. Port-forwarding them
#      causes "address already in use" conflicts and is unnecessary.
#      doctor() now correctly checks only the 3 ClusterIP port-forwards:
#        alloy :12345, tempo :3200, loki :3100
#      The LoadBalancer services are checked via their actual external IPs.
#
# [v2] verify() Loki label check updated.
#      loki.source.kubernetes component (v4 alloy.yaml) produces streams with
#      job label "loki.source.kubernetes.pods". The previous check queried for
#      the "pod" label which always exists but doesn't confirm the pipeline
#      is running. New check queries distributor lines_received metric directly
#      for a definitive "data is flowing" confirmation.
#
# [v2] resume() port-forward: only restarts ClusterIP port-forwards (matching
#      start.sh v6 PF_DEFS). No longer tries to port-forward LoadBalancer svcs.
#
# [v1] stop: reverse dependency order (alloy → boutique → observability).
# [v1] nuke: deletes PriorityClasses (cluster-scoped).
# [v1] logs: --previous flag for post-crash inspection.
# [v1] debug: ResourceQuota, OOM check, HPA TARGETS.
# [v1] budget, cart-debug, hpa-watch, restart, top, suspend, resume,
#      grafana-export, doctor commands.
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

get_kind_for_svc() {
  case "$1" in
    alloy) echo "daemonset" ;;
    node-exporter) echo "daemonset" ;;
    *)     echo "deployment" ;;
  esac
}

# Helper: get LoadBalancer external IP for a service
get_lb_ip() {
  local svc=$1 ns=$2
  kubectl get svc "$svc" -n "$ns" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo ""
}

# ── stop ──────────────────────────────────────────────────────────────────────
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

  info "Deleting PriorityClasses (cluster-scoped)..."
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

  header "HPA (with TARGETS)"
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

  header "CartService logs (last 30)"
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
logs() {
  local svc="${2:-alloy}"
  local ns="${3:-$OBS}"
  local previous_flag=""
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

  _check "spanmetrics latency bucket"   'count(traces_spanmetrics_duration_milliseconds_bucket)'
  _check "spanmetrics calls total"      'count(traces_spanmetrics_calls_total)'
  _check "p95 latency (all services)"   'histogram_quantile(0.95,sum by(le,service_name)(rate(traces_spanmetrics_duration_milliseconds_bucket[5m])))'
  _check "p99 latency (all services)"   'histogram_quantile(0.99,sum by(le,service_name)(rate(traces_spanmetrics_duration_milliseconds_bucket[5m])))'
  _check "request rate by service"      'sum by(service_name)(rate(traces_spanmetrics_calls_total[5m]))'
  _check "service graph edges"          'count(traces_service_graph_request_total)'
  _check "kube-state-metrics HPA data"  'kube_horizontalpodautoscaler_status_current_replicas'
  _check "node CPU usage"               'instance:node_cpu_utilisation:rate5m'
  _check "Alloy OTLP spans received"    'otelcol_receiver_accepted_spans_total'

  $pf_started && kill "$pf_pid" 2>/dev/null; pf_started=false

  echo ""
  info "Checking Loki log pipeline..."

  # [v2] Check Loki distributor metric directly — definitive "data is flowing" signal.
  # loki.source.kubernetes sends to distributor → distributor.lines_received_total > 0
  # confirms end-to-end pipeline health regardless of chunk flush timing.
  local loki_pf_started=false
  local loki_pid=0
  if ! curl -sf "http://localhost:3100/ready" -o /dev/null -m 3 2>/dev/null; then
    kubectl port-forward -n "$OBS" svc/loki 3100:3100 &>/tmp/pf-verify-loki.log &
    loki_pid=$!
    sleep 3
    loki_pf_started=true
  fi

  local lines_received
  lines_received=$(curl -sg "http://localhost:3100/metrics" 2>/dev/null | \
    grep "^loki_distributor_lines_received_total" | \
    awk '{print $2}' | head -1 || echo "0")

  if [[ "${lines_received:-0}" != "0" && "${lines_received:-0}" != "" ]]; then
    printf "  ${GREEN}✓${NC} Loki: receiving logs — distributor lines_received_total = %s\n" "$lines_received"
    # Also show label count if available
    local label_count
    label_count=$(curl -sg "http://localhost:3100/loki/api/v1/labels" 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")
    printf "  ${GREEN}✓${NC} Loki: %s label(s) queryable (chunks may still be flushing if 0)\n" "$label_count"
  else
    printf "  ${YELLOW}~${NC} Loki: no lines received yet — Alloy may still be discovering pods\n"
    printf "       Check: kubectl logs -n observability daemonset/alloy --tail=20\n"
  fi

  $loki_pf_started && kill "$loki_pid" 2>/dev/null || true

  # Tempo check
  echo ""
  info "Checking Tempo trace pipeline..."
  local tempo_pf_started=false
  local tempo_pid=0
  if ! curl -sf "http://localhost:3200/ready" -o /dev/null -m 3 2>/dev/null; then
    kubectl port-forward -n "$OBS" svc/tempo 3200:3200 &>/tmp/pf-verify-tempo.log &
    tempo_pid=$!
    sleep 3
    tempo_pf_started=true
  fi

  local tempo_ready
  tempo_ready=$(curl -sf "http://localhost:3200/ready" 2>/dev/null || echo "not ready")
  printf "  ${GREEN}✓${NC} Tempo: %s\n" "$tempo_ready"

  $tempo_pf_started && kill "$tempo_pid" 2>/dev/null || true
  echo ""
}

# ── budget ────────────────────────────────────────────────────────────────────
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
    -o custom-columns='HPA:.metadata.name,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,MAX:.spec.maxReplicas' \
    2>/dev/null || true
}

# ── cart-debug ─────────────────────────────────────────────────────────────────
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
    || info "No previous container (no recent crash)"

  header "Redis pod status"
  kubectl get pods -n "$APP" -l app=redis -o wide 2>/dev/null
  kubectl top pods -n "$APP" -l app=redis 2>/dev/null || true

  header "Redis logs (last 30)"
  kubectl logs -n "$APP" deployment/redis --tail=30 2>/dev/null || warn "Redis not running"

  header "OOM events — boutique namespace"
  kubectl get events -n "$APP" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | \
    grep -iE "(OOMKill|oom|Evict|BackOff)" | tail -20 || info "No OOM/eviction events"

  header "Recent Warning events — boutique"
  kubectl get events -n "$APP" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
}

# ── hpa-watch ─────────────────────────────────────────────────────────────────
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

# ── suspend ────────────────────────────────────────────────────────────────────
suspend() {
  info "Suspending platform — scaling all deployments to 0..."
  info "(PVCs, ConfigMaps, namespaces preserved — resume is fast)"

  pkill -f "kubectl port-forward" 2>/dev/null || true
  [[ -f "$PF_PID_FILE" ]] && rm -f "$PF_PID_FILE"
  info "Port-forwards stopped ✓"

  for dep in grafana prometheus loki tempo kube-state-metrics; do
    kubectl scale deployment/$dep -n observability --replicas=0 2>/dev/null && \
      info "  $dep → 0" || true
  done
  kubectl patch daemonset alloy -n observability \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"suspend":"true"}}}}}' \
    2>/dev/null && info "  alloy (DaemonSet) → suspended" || true

  for dep in frontend cartservice checkoutservice productcatalogservice \
             currencyservice recommendationservice shippingservice \
             paymentservice emailservice adservice redis; do
    kubectl scale deployment/$dep -n boutique --replicas=0 2>/dev/null && \
      info "  $dep → 0" || true
  done

  echo ""
  info "Platform suspended ✓ — Docker Desktop RAM freed"
  info "To resume:  bash scripts/manage.sh resume"
  info "To destroy: bash scripts/manage.sh nuke"
}

# ── resume ─────────────────────────────────────────────────────────────────────
resume() {
  info "Resuming platform — restoring replica counts..."

  if ! kubectl get namespace boutique &>/dev/null 2>&1; then
    warn "Boutique namespace missing — cluster was likely wiped by a Docker Desktop upgrade."
    warn "Resume is not possible. Running full start instead..."
    echo ""
    SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$SCRIPT_DIR_LOCAL/start.sh"
  fi
  if ! kubectl get namespace observability &>/dev/null 2>&1; then
    warn "Observability namespace missing — cluster state is incomplete."
    warn "Running full start instead..."
    echo ""
    SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec bash "$SCRIPT_DIR_LOCAL/start.sh"
  fi

  if ! kubectl get pvc grafana-pvc -n observability &>/dev/null 2>&1; then
    warn "grafana-pvc missing — dashboard edits from previous session are lost."
    warn "Continuing resume — Grafana will re-seed from ConfigMap defaults."
  fi

  info "Re-applying cluster infra..."
  CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}}")/.." && pwd)/cluster"
  if ! kubectl apply -f "$CLUSTER_DIR/metrics-server.yaml" 2>/dev/null; then
    warn "  metrics-server apply failed (immutable selector) — forcing recreate..."
    kubectl delete deployment metrics-server -n kube-system --ignore-not-found 2>/dev/null
    kubectl apply -f "$CLUSTER_DIR/metrics-server.yaml"
  fi
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=60s 2>/dev/null \
    && info "  metrics-server ✓" || warn "  metrics-server slow"

  kubectl patch daemonset alloy -n observability \
    --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/suspend"}]' \
    2>/dev/null && info "  alloy DaemonSet → restored" || true

  kubectl scale deployment/prometheus    -n observability --replicas=1 2>/dev/null
  kubectl scale deployment/loki         -n observability --replicas=1 2>/dev/null
  kubectl scale deployment/tempo        -n observability --replicas=1 2>/dev/null
  kubectl scale deployment/grafana      -n observability --replicas=1 2>/dev/null
  kubectl scale deployment/kube-state-metrics -n observability --replicas=1 2>/dev/null

  kubectl scale deployment/redis               -n boutique --replicas=1 2>/dev/null
  kubectl scale deployment/cartservice         -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/frontend            -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/checkoutservice     -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/productcatalogservice -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/currencyservice     -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/recommendationservice -n boutique --replicas=2 2>/dev/null
  kubectl scale deployment/shippingservice     -n boutique --replicas=1 2>/dev/null
  kubectl scale deployment/paymentservice      -n boutique --replicas=1 2>/dev/null
  kubectl scale deployment/emailservice        -n boutique --replicas=1 2>/dev/null
  kubectl scale deployment/adservice           -n boutique --replicas=1 2>/dev/null

  info "Replica counts restored ✓"

  info "Waiting for observability stack to be ready..."
  kubectl rollout status deployment/prometheus -n observability --timeout=120s 2>/dev/null \
    && info "  prometheus ✓" || warn "  prometheus slow"
  kubectl rollout status deployment/grafana -n observability --timeout=120s 2>/dev/null \
    && info "  grafana ✓" || warn "  grafana slow"
  kubectl rollout status deployment/loki  -n observability --timeout=60s 2>/dev/null \
    && info "  loki ✓" || true
  kubectl rollout status deployment/tempo -n observability --timeout=60s 2>/dev/null \
    && info "  tempo ✓" || true

  # [v2] Only restart ClusterIP port-forwards — LoadBalancer services don't need them
  info "Restarting port-forwards (ClusterIP services only)..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 1
  kubectl port-forward -n observability svc/alloy 12345:12345 > /tmp/pf-alloy.log 2>&1 &
  kubectl port-forward -n observability svc/tempo 3200:3200   > /tmp/pf-tempo.log 2>&1 &
  kubectl port-forward -n observability svc/loki  3100:3100   > /tmp/pf-loki.log  2>&1 &
  sleep 3

  echo ""
  info "Waiting for cartservice (.NET JIT — up to 90s)..."
  kubectl rollout status deployment/cartservice -n boutique --timeout=150s 2>/dev/null || \
    warn "Cart still starting — check: kubectl get pods -n boutique"

  # Get actual LoadBalancer IPs
  GRAFANA_IP=$(get_lb_ip grafana observability)
  PROM_IP=$(get_lb_ip prometheus observability)

  echo ""
  info "Platform resumed ✓"
  echo ""
  echo "  Boutique:    http://localhost:8080"
  echo "  Grafana:     http://${GRAFANA_IP:-172.18.0.x}:3000   admin/admin"
  echo "  Prometheus:  http://${PROM_IP:-172.18.0.x}:9090"
  echo "  Alloy UI:    http://localhost:12345"
  echo "  Tempo:       http://localhost:3200"
  echo "  Loki:        http://localhost:3100"
  echo ""
  echo "  Smoke: k6 run scripts/load-test_10vusers.js"
}

# ── grafana-export ─────────────────────────────────────────────────────────────
grafana_export() {
  local out_dir="${REPO_ROOT}/observability/grafana/dashboards"
  mkdir -p "$out_dir"

  # Determine Grafana URL — LoadBalancer IP or localhost port-forward
  local grafana_url="http://localhost:3000"
  local lb_ip
  lb_ip=$(get_lb_ip grafana observability)
  if [[ -n "$lb_ip" ]]; then
    grafana_url="http://${lb_ip}:3000"
  fi

  info "Exporting Grafana dashboards to $out_dir ..."
  info "Using Grafana at: $grafana_url"

  local uids
  uids=$(curl -sf "${grafana_url}/api/search?type=dash-db" \
    -u admin:admin 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for d in data:
    print(d['uid'] + '|' + d['title'].replace('/', '-').replace(' ', '_'))
" 2>/dev/null)

  if [[ -z "$uids" ]]; then
    warn "Could not reach Grafana at $grafana_url"
    warn "Try: bash scripts/start.sh --pf-only  then retry"
    return 1
  fi

  local count=0
  while IFS='|' read -r uid title; do
    local fname="${out_dir}/${uid}-${title}.json"
    if curl -sf "${grafana_url}/api/dashboards/uid/$uid" \
        -u admin:admin 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = d['dashboard']
out['id'] = None
json.dump(out, sys.stdout, indent=2)
" > "$fname" 2>/dev/null; then
      info "  Exported: $title → $(basename $fname)"
      count=$((count + 1))
    else
      warn "  Failed: $title (uid: $uid)"
    fi
  done <<< "$uids"

  echo ""
  info "$count dashboard(s) exported to $out_dir"
  warn "NEXT STEP: commit exported dashboards:"
  warn "  git add observability/grafana/dashboards/ && git commit -m 'export: grafana dashboards'"
}

# ── doctor ────────────────────────────────────────────────────────────────────
# [v2] Updated: loki-pvc added, LoadBalancer services checked via IP not port-forward.
doctor() {
  local warn_count=0
  pass() { echo -e "  ${GREEN}✓${NC} $*"; }
  fail() { echo -e "  ${RED}✗${NC} $*"; warn_count=$((warn_count+1)); }
  maybe() { echo -e "  ${YELLOW}~${NC} $*"; }

  echo ""
  echo -e "${BOLD}── Cluster ──────────────────────────────────────${NC}"
  kubectl cluster-info &>/dev/null && pass "cluster reachable" || fail "cluster unreachable — is Docker Desktop running?"
  kubectl get ns boutique &>/dev/null && pass "boutique namespace" || fail "boutique namespace missing — run: bash scripts/start.sh"
  kubectl get ns observability &>/dev/null && pass "observability namespace" || fail "observability namespace missing — run: bash scripts/start.sh"

  echo ""
  echo -e "${BOLD}── Pods ─────────────────────────────────────────${NC}"
  local not_running
  not_running=$(kubectl get pods -n observability --field-selector='status.phase!=Running' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v "^$" || true)
  not_running+=" "$(kubectl get pods -n boutique --field-selector='status.phase!=Running' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v "^$" || true)
  not_running=$(echo "$not_running" | tr ' ' '\n' | grep -v "^$" || true)
  if [[ -z "$not_running" ]]; then
    pass "all pods Running"
  else
    fail "non-running pods: $(echo $not_running | tr '\n' ' ')"
  fi

  echo ""
  echo -e "${BOLD}── PVCs ─────────────────────────────────────────${NC}"
  # [v2] loki-pvc added — loki.yaml v2 adds PVC for log persistence
  for pvc in grafana-pvc prometheus-pvc tempo-pvc loki-pvc; do
    local pvc_status
    pvc_status=$(kubectl get pvc $pvc -n observability -o jsonpath='{.status.phase}' 2>/dev/null || echo "MISSING")
    if [[ "$pvc_status" == "Bound" ]]; then
      pass "$pvc: Bound"
    else
      fail "$pvc: $pvc_status"
    fi
  done

  echo ""
  echo -e "${BOLD}── Services ─────────────────────────────────────${NC}"
  # [v2] LoadBalancer services — check via actual external IP, not port-forward
  local frontend_ip grafana_ip prom_ip
  frontend_ip=$(kubectl get svc frontend -n boutique \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  grafana_ip=$(get_lb_ip grafana observability)
  prom_ip=$(get_lb_ip prometheus observability)

  if curl -sf "http://localhost:8080/_healthz" -o /dev/null -m 5 2>/dev/null; then
    pass "boutique frontend :8080 (localhost)"
  elif [[ -n "$frontend_ip" ]] && curl -sf "http://${frontend_ip}:8080/_healthz" -o /dev/null -m 5 2>/dev/null; then
    pass "boutique frontend :8080 (${frontend_ip})"
  else
    fail "boutique frontend :8080 — check: kubectl get pods -n boutique"
  fi

  # Try localhost port-forward first (always works on macOS), fall back to LB IP
  if curl -sf "http://localhost:3000/api/health" -o /dev/null -m 5 2>/dev/null; then
    pass "grafana :3000 (localhost port-forward)"
  elif [[ -n "$grafana_ip" ]] && curl -sf "http://${grafana_ip}:3000/api/health" -o /dev/null -m 5 2>/dev/null; then
    pass "grafana :3000 (${grafana_ip})"
  else
    fail "grafana :3000 — run: bash scripts/start.sh --pf-only"
  fi

  if curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 5 2>/dev/null; then
    pass "prometheus :9090 (localhost port-forward)"
  elif [[ -n "$prom_ip" ]] && curl -sf "http://${prom_ip}:9090/-/healthy" -o /dev/null -m 5 2>/dev/null; then
    pass "prometheus :9090 (${prom_ip})"
  else
    fail "prometheus :9090 — run: bash scripts/start.sh --pf-only"
  fi

  echo ""
  echo -e "${BOLD}── Port-forwards (ClusterIP) ────────────────────${NC}"
  # [v2] Only check ClusterIP port-forwards — these are the 3 that actually need forwarding
  curl -sf http://localhost:12345/-/ready -o /dev/null -m 3 && pass "alloy :12345" || \
    fail "alloy :12345 — run: bash scripts/start.sh --pf-only"
  curl -sf http://localhost:3200/ready -o /dev/null -m 3 && pass "tempo :3200" || \
    fail "tempo :3200 — run: bash scripts/start.sh --pf-only"
  curl -sf http://localhost:3100/ready -o /dev/null -m 3 && pass "loki :3100" || \
    fail "loki :3100 — run: bash scripts/start.sh --pf-only"

  echo ""
  echo -e "${BOLD}── Observability pipeline ───────────────────────${NC}"

  # Spanmetrics via Prometheus
  local prom_base="http://localhost:9090"
  local series
  series=$(curl -sf "${prom_base}/api/v1/query?query=traces_spanmetrics_calls_total" \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")
  if [[ "$series" -gt 0 ]]; then
    pass "spanmetrics flowing ($series series)"
  else
    maybe "spanmetrics: 0 series — send traffic: k6 run scripts/load-test_10vusers.js"
  fi

  # Loki pipeline
  local loki_lines
  loki_lines=$(curl -sf "http://localhost:3100/metrics" 2>/dev/null | \
    grep "^loki_distributor_lines_received_total" | awk '{print $2}' | head -1 || echo "0")
  if [[ "${loki_lines:-0}" != "0" && "${loki_lines:-0}" != "" ]]; then
    pass "Loki log pipeline — ${loki_lines} lines received"
  else
    maybe "Loki: no lines yet — check alloy logs"
  fi

  echo ""
  if [[ $warn_count -eq 0 ]]; then
    echo -e "${GREEN}All checks passed ✓ — stack is healthy${NC}"
  else
    echo -e "${RED}$warn_count check(s) failed — see above${NC}"
  fi
  echo ""
}

case "$CMD" in
  stop)           stop ;;
  nuke)           nuke ;;
  status)         status ;;
  debug)          debug ;;
  logs)           logs "$@" ;;
  verify)         verify ;;
  budget)         budget ;;
  cart-debug)     cart_debug ;;
  hpa-watch)      hpa_watch ;;
  restart)        restart_svc "$@" ;;
  top)            top_pods ;;
  suspend)        suspend ;;
  resume)         resume ;;
  grafana-export) grafana_export ;;
  doctor)         doctor ;;
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
    echo "  suspend                 scale all to 0, free RAM (keeps PVCs)"
    echo "  resume                  restore from suspend (fast, no image pulls)"
    echo "  grafana-export          export dashboard edits to JSON files"
    echo "  doctor                  health check — cluster, pods, PVCs, pipeline"
    echo ""
    echo "Startup:    bash scripts/start.sh"
    echo "Stability:  bash scripts/verify-stability.sh [--short|--no-k6]"
    echo ""
    exit 1
    ;;
esac
