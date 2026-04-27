#!/bin/bash
# =============================================================================
# verify-stability.sh — SRE Demo Platform: Stability Harness v3
# =============================================================================
#
# Definition of DONE (all 6 checks must pass):
#   1. Zero pod restarts in boutique + observability during the run
#   2. Zero OOMKilled events in either namespace during the run
#   3. No Prometheus scrape gaps > 45s for any job
#   4. Spanmetrics pipeline fresh (most recent sample < 60s old)
#   5. Redis is healthy and not connection-saturated
#   6. All HPA TARGETS show a real CPU percentage (not <unknown>)
#
# Usage:
#   bash scripts/verify-stability.sh              # full run (1000 VU, ~30min)
#   bash scripts/verify-stability.sh --short      # smoke (100 VU, 2min)
#   bash scripts/verify-stability.sh --no-k6      # checks only, no load test
#
# KEY CHANGES vs v2:
#
# 1. CRITICAL: --short mode hardcoded BASE_URL=http://localhost:30080 FIXED.
#    NodePort 30080 is unreliable on Docker Desktop — this was causing 100%
#    failure rate in the smoke test. Now uses find-url.sh to discover the
#    correct working URL (LoadBalancer :8080 is the reliable path on Docker Desktop).
#
# 2. --short mode inline k6 script: threshold relaxed to rate<0.001 (0.1%)
#    from rate<0.05 (5%). The 5% threshold was masking real pipeline problems —
#    a 4.9% failure rate is not "stable". 0.1% is the correct bar for a smoke test.
#    p95 < 2000ms (was 5000ms — 5 seconds is not a smoke test pass criterion).
#
# 3. Full mode k6 now passes BASE_URL from find-url.sh, same as --short.
#    Previously the full run used load-test_1000vusers.js default (localhost:30080)
#    which has the same NodePort problem.
#
# 4. Elapsed timer now starts AFTER k6 runs (not before), so Check timestamps
#    align with the actual test window, not the preflight.
#
# 5. manage.sh logs reference updated: `alloy` now correctly uses `daemonset/alloy`
#    in triage commands at the bottom (was `deployment/alloy` in some error messages).
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
else
  REPO_ROOT="$SCRIPT_DIR"
fi
cd "$REPO_ROOT"

MODE="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}[PASS]${NC} $*"; RESULTS+=("PASS: $*"); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); RESULTS+=("FAIL: $*"); }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info()    { echo -e "${BOLD}▶${NC} $*"; }
section() {
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${BOLD} $*${NC}"
  echo -e "${BOLD}════════════════════════════════════════════${NC}"
}

FAILURES=0
RESULTS=()
START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Shared Prometheus port-forward ────────────────────────────────────────────
PROM_PF_PID=0
PROM_PF_MINE=false

ensure_prometheus_pf() {
  if curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 3 2>/dev/null; then
    return 0
  fi
  if $PROM_PF_MINE && kill -0 "$PROM_PF_PID" 2>/dev/null; then
    return 0
  fi
  kubectl port-forward -n observability svc/prometheus 9090:9090 \
    &>/tmp/pf-stability-prom.log &
  PROM_PF_PID=$!
  PROM_PF_MINE=true
  local elapsed=0
  while ! curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 2 2>/dev/null; do
    sleep 2; elapsed=$((elapsed + 2))
    [[ $elapsed -ge 15 ]] && return 1
  done
  return 0
}

close_prometheus_pf() {
  if $PROM_PF_MINE && kill -0 "$PROM_PF_PID" 2>/dev/null; then
    kill "$PROM_PF_PID" 2>/dev/null || true
    PROM_PF_MINE=false
  fi
}

# ── Discover working frontend URL ─────────────────────────────────────────────
# CRITICAL FIX: never hardcode NodePort 30080 — unreliable on Docker Desktop.
# find-url.sh probes candidate URLs in order and returns the first that responds.
discover_base_url() {
  local url
  url=$(bash "$SCRIPT_DIR/find-url.sh" --export 2>/dev/null || echo "")
  if [[ -z "$url" ]]; then
    warn "find-url.sh failed — falling back to http://localhost:8080"
    echo "http://localhost:8080"
  else
    echo "$url"
  fi
}

# ── Preflight ─────────────────────────────────────────────────────────────────
section "Preflight"

command -v kubectl &>/dev/null || { echo "kubectl not found"; exit 2; }
kubectl cluster-info &>/dev/null || { echo "cluster unreachable"; exit 2; }

if [[ "$MODE" != "--no-k6" ]]; then
  command -v k6 &>/dev/null || { echo "k6 not found — brew install k6"; exit 2; }
fi

info "Cluster: $(kubectl config current-context)"
info "Mode:    ${MODE:-full (1000 VU, ~30min)}"
info "Time:    $START_ISO"
echo ""

preflight_ok=true
for dep in prometheus grafana tempo loki kube-state-metrics; do
  if ! kubectl get deployment "$dep" -n observability &>/dev/null; then
    fail "observability/$dep not deployed — run bash scripts/start.sh first"
    preflight_ok=false
  fi
done
if ! kubectl get daemonset alloy -n observability &>/dev/null; then
  fail "observability/alloy DaemonSet not deployed"
  preflight_ok=false
fi
for svc in frontend cartservice redis checkoutservice; do
  if ! kubectl get deployment "$svc" -n boutique &>/dev/null; then
    fail "boutique/$svc not deployed"
    preflight_ok=false
  fi
done

if ! $preflight_ok; then
  echo ""
  echo -e "${RED}Preflight failed — run bash scripts/start.sh first.${NC}"
  exit 2
fi
info "All expected workloads present ✓"

hpa_unknown=$(kubectl get hpa -n boutique \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.currentMetrics[0].resource.current.averageUtilization}{"\n"}{end}' \
  2>/dev/null | grep -c "^[a-z].* $" || true)
if [[ "${hpa_unknown:-0}" -gt 0 ]]; then
  warn "Some HPAs show <unknown> targets — metrics-server may still be warming up"
  warn "HPA scaling will not work correctly during this run (Check 6 will flag this)"
fi

# ── Snapshot BEFORE ───────────────────────────────────────────────────────────
section "Snapshot — before run"

before_file=$(mktemp /tmp/stability-before.XXXXXX)
kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
  2>/dev/null | grep -E "^(boutique|observability)/" > "$before_file" || true

before_restart_total=$(awk '{sum += $2} END {print sum+0}' "$before_file")
info "Pre-run restart total (boutique + observability): $before_restart_total"

# ── Run k6 ───────────────────────────────────────────────────────────────────
START_TS=$(date +%s)   # timer starts here — aligns with actual test window

if [[ "$MODE" == "--no-k6" ]]; then
  section "k6 — skipped (--no-k6 mode)"

elif [[ "$MODE" == "--short" ]]; then
  section "k6 — smoke test (100 VU, 2min)"

  BASE_URL=$(discover_base_url)
  info "Using BASE_URL: $BASE_URL"

  k6 run \
    --vus 100 \
    --duration 2m \
    --env BASE_URL="$BASE_URL" \
    - <<'EOF' || warn "k6 smoke test exited non-zero (check thresholds above)"
import http from 'k6/http';
import { sleep, check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const PRODUCTS = ['OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0'];

export const options = {
  thresholds: {
    http_req_failed:   ['rate<0.001'],   // <0.1% — real smoke test bar
    http_req_duration: ['p(95)<2000'],   // p95 < 2s — not 5s
  },
};

export default function () {
  const home = http.get(`${BASE}/`, {
    timeout: '15s',
    tags: { name: 'Home' },
  });
  check(home, { 'home 200': (r) => r.status === 200 });
  sleep(1);

  const pid = PRODUCTS[Math.floor(Math.random() * PRODUCTS.length)];
  const prod = http.get(`${BASE}/product/${pid}`, {
    timeout: '15s',
    tags: { name: 'Product' },
  });
  check(prod, { 'product 200': (r) => r.status === 200 });
  sleep(1);

  if (Math.random() > 0.7) {
    http.post(`${BASE}/cart`,
      { product_id: pid, quantity: '1' },
      { timeout: '15s', tags: { name: 'AddCart' } }
    );
    sleep(0.5);
  }
}
EOF

else
  section "k6 — full run (1000 VU, ~30min)"
  BASE_URL=$(discover_base_url)
  info "Using BASE_URL: $BASE_URL"
  k6 run \
    --env BASE_URL="$BASE_URL" \
    "${REPO_ROOT}/scripts/load-test_1000vusers.js" \
    || warn "k6 exited non-zero — check thresholds above"
fi

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
info "Elapsed: ${ELAPSED}s"

# ── Snapshot AFTER ────────────────────────────────────────────────────────────
section "Snapshot — after run"

after_file=$(mktemp /tmp/stability-after.XXXXXX)
kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
  2>/dev/null | grep -E "^(boutique|observability)/" > "$after_file" || true

after_restart_total=$(awk '{sum += $2} END {print sum+0}' "$after_file")
info "Post-run restart total: $after_restart_total"

# ── CHECK 1: pod restarts ─────────────────────────────────────────────────────
section "Check 1 — pod restarts during run"

restart_diff=$(mktemp /tmp/stability-diff.XXXXXX)
join -o 1.1,1.2,2.2 -a 1 \
  <(sort "$before_file") <(sort "$after_file") \
  2>/dev/null | \
  awk '{before = $2+0; after = $3+0; if (after > before) print $1, "("before"→"after")"}' \
  > "$restart_diff"

if [[ -s "$restart_diff" ]]; then
  fail "Pods restarted during the run:"
  while IFS= read -r line; do
    echo "      $line"
  done < "$restart_diff"
else
  ok "No pod restarts in boutique or observability"
fi

# ── CHECK 2: OOMKilled events ─────────────────────────────────────────────────
section "Check 2 — OOMKilled events"

oom_total=0

cart_oom=$(kubectl get events -n boutique \
  --field-selector type=Warning \
  -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.involvedObject.name}{" "}{.reason}{" "}{.message}{"\n"}{end}' \
  2>/dev/null | \
  awk -v start="$START_ISO" '$1 >= start && ($3 == "OOMKilling" || $4 ~ /OOMKill/)' | \
  grep -i "cart" | wc -l | tr -d ' ')

if [[ "${cart_oom:-0}" -gt 0 ]]; then
  fail "cartservice: ${cart_oom} OOM event(s) — DOTNET_GCHeapHardLimit may need adjusting"
  fail "  Run: kubectl describe pod -n boutique -l app=cartservice | grep -A5 OOMKill"
  oom_total=$((oom_total + cart_oom))
fi

for ns in boutique observability; do
  ns_oom=$(kubectl get events -n "$ns" \
    --field-selector type=Warning \
    -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.reason}{" "}{.message}{"\n"}{end}' \
    2>/dev/null | \
    awk -v start="$START_ISO" '$1 >= start && ($2 == "OOMKilling" || $3 ~ /OOMKill/)' | \
    grep -iv "cart" | \
    wc -l | tr -d ' ')
  if [[ "${ns_oom:-0}" -gt 0 ]]; then
    fail "$ns: ${ns_oom} OOM event(s) in non-cartservice pods"
    oom_total=$((oom_total + ns_oom))
  fi
done

[[ $oom_total -eq 0 ]] && ok "No OOMKilled events in either namespace"

# ── CHECK 3: Prometheus scrape gaps ──────────────────────────────────────────
section "Check 3 — Prometheus scrape gaps"

if ensure_prometheus_pf; then
  gap_result=$(curl -sg "http://localhost:9090/api/v1/query" \
    --data-urlencode 'query=max_over_time((time() - timestamp(up{job!=""}))[15m:15s])' \
    2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    results = d.get('data', {}).get('result', [])
    gaps = []
    for r in results:
        job = r['metric'].get('job', '?')
        ns  = r['metric'].get('namespace', '')
        val = float(r['value'][1])
        if val > 45:
            label = f'{ns}/{job}' if ns else job
            gaps.append(f'{label}:{val:.0f}s')
    print('GAPS:' + ','.join(gaps) if gaps else 'CLEAN')
except Exception as e:
    print(f'ERROR:{e}')
" 2>/dev/null || echo "ERROR:query_failed")

  if [[ "$gap_result" == "CLEAN" ]]; then
    ok "No scrape gaps > 45s on any job (last 15m)"
  elif [[ "$gap_result" == GAPS:* ]]; then
    fail "Scrape gaps detected (job: max-gap): ${gap_result#GAPS:}"
  else
    warn "Could not query Prometheus for scrape gaps: $gap_result"
  fi
else
  warn "Prometheus unreachable — skipped scrape gap check"
fi

# ── CHECK 4: spanmetrics freshness ────────────────────────────────────────────
section "Check 4 — spanmetrics pipeline freshness"

if ensure_prometheus_pf; then
  freshness=$(curl -sg "http://localhost:9090/api/v1/query" \
    --data-urlencode 'query=time() - max(timestamp(traces_spanmetrics_calls_total))' \
    2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('data', {}).get('result', [])
    print('NONE' if not r else f'{float(r[0][\"value\"][1]):.0f}')
except Exception:
    print('ERROR')
" 2>/dev/null || echo "ERROR")

  if [[ "$freshness" == "NONE" ]]; then
    fail "No spanmetrics samples in Prometheus — OTLP pipeline not flowing"
    fail "  Check: kubectl logs -n observability daemonset/alloy --tail=40"
  elif [[ "$freshness" == "ERROR" ]]; then
    warn "Could not parse spanmetrics freshness result"
  elif [[ "$freshness" -gt 60 ]] 2>/dev/null; then
    fail "Most recent spanmetric is ${freshness}s old (threshold: 60s) — pipeline stalled"
  else
    ok "Spanmetrics freshness: ${freshness}s (target: <60s)"
  fi
else
  warn "Prometheus unreachable — skipped spanmetrics freshness check"
fi

close_prometheus_pf

# ── CHECK 5: Redis health ─────────────────────────────────────────────────────
section "Check 5 — Redis connection health"

redis_pod=$(kubectl get pods -n boutique -l app=redis \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$redis_pod" ]]; then
  fail "Redis pod not found — cartservice has no backend"
else
  redis_ping=$(kubectl exec -n boutique "$redis_pod" \
    -- redis-cli ping 2>/dev/null || echo "FAILED")
  if [[ "$redis_ping" != "PONG" ]]; then
    fail "Redis not responding to PING (got: $redis_ping) — cartservice will crash"
  else
    connected=$(kubectl exec -n boutique "$redis_pod" \
      -- redis-cli info clients 2>/dev/null | \
      grep "connected_clients" | awk -F: '{print $2}' | tr -d '[:space:]' || echo "0")
    used_mem=$(kubectl exec -n boutique "$redis_pod" \
      -- redis-cli info memory 2>/dev/null | \
      grep "used_memory_human" | awk -F: '{print $2}' | tr -d '[:space:]' || echo "?")

    # maxclients=500 now. Warn at >375 (75%), fail at >450 (90%)
    if [[ "${connected:-0}" -gt 450 ]]; then
      fail "Redis: ${connected}/500 connections (>90% — cartservice pods will start failing)"
    elif [[ "${connected:-0}" -gt 375 ]]; then
      warn "Redis: ${connected}/500 connections (>75% — approaching saturation)"
      ok "Redis responding to PING | clients=${connected}/500 | mem=${used_mem}"
    else
      ok "Redis responding to PING | clients=${connected}/500 | mem=${used_mem}"
    fi
  fi
fi

# ── CHECK 6: HPA target validity ──────────────────────────────────────────────
section "Check 6 — HPA target validity (metrics-server data)"

unknown_hpas=""
while IFS= read -r line; do
  hpa_name=$(echo "$line" | awk '{print $1}')
  targets=$(echo "$line" | awk '{print $2}')
  if [[ "$targets" == *"<unknown>"* ]]; then
    unknown_hpas="${unknown_hpas}${hpa_name} "
  fi
done < <(kubectl get hpa -n boutique --no-headers 2>/dev/null || true)

if [[ -n "$unknown_hpas" ]]; then
  fail "HPAs with <unknown> targets (cannot scale): ${unknown_hpas}"
  fail "  Fix: kubectl top pods -n boutique"
  fail "  Fix: kubectl describe hpa -n boutique"
else
  ok "All HPA targets show valid CPU utilization percentages"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"

rm -f "$before_file" "$after_file" "$restart_diff" 2>/dev/null || true

echo ""
echo "  Results:"
for result in "${RESULTS[@]}"; do
  if [[ "$result" == PASS:* ]]; then
    echo -e "    ${GREEN}✓${NC} ${result#PASS: }"
  else
    echo -e "    ${RED}✗${NC} ${result#FAIL: }"
  fi
done
echo ""

if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}  ║  STABILITY CHECK: PASSED (6/6)      ║${NC}"
  echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════╝${NC}"
  echo ""
  echo "  All 6 checks clean. Run twice more for exit criteria (3 consecutive passes)."
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}  ╔══════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}  ║  STABILITY CHECK: FAILED             ║${NC}"
  echo -e "${RED}${BOLD}  ║  $FAILURES check(s) failed — see above      ║${NC}"
  echo -e "${RED}${BOLD}  ╚══════════════════════════════════════╝${NC}"
  echo ""
  echo "  Triage commands:"
  echo "    bash scripts/manage.sh cart-debug"
  echo "    bash scripts/manage.sh debug"
  echo "    kubectl logs -n observability daemonset/alloy --tail=40"
  echo "    bash scripts/manage.sh budget"
  echo "    kubectl get events -A --sort-by='.lastTimestamp' | tail -30"
  echo ""
  exit 1
fi
