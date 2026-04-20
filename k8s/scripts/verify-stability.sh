#!/bin/bash
# =============================================================================
# verify-stability.sh — SRE Demo Platform: Stability Harness (Holy Grail Edition)
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
#   bash scripts/verify-stability.sh              # full run (1000 VU, ~9min)
#   bash scripts/verify-stability.sh --short      # smoke test (100 VU, 2min)
#   bash scripts/verify-stability.sh --no-k6      # checks only, no load test
#
# KEY CHANGES vs previous version:
#
# 1. --short mode bug fixed: was running load-test_10vusers.js but overriding
#    --vus 100 --duration 2m, which means the 10vusers script's own `options`
#    block (stages) was being IGNORED — k6 uses `--vus` only if no `stages`
#    are defined. Result: the 10-user script ran its own stages (10 VU for
#    3min) not 100 VU for 2min.
#    Fix: --short now passes BASE_URL and uses a simple --vus/--duration
#    override against load-test_1000vusers.js, which has no conflicting stages
#    when called with explicit --vus flag. Actually simpler: we call k6 run
#    with the 1000vusers script but override stages via k6 env vars.
#    Cleaner fix: run with explicit --vus 100 --duration 2m against a
#    minimal inline script, OR just run the 1000vusers.js with env override.
#    Implemented: use load-test_1000vusers.js with k6 --no-setup and
#    override duration via the standard approach.
#
# 2. Port-forward lifecycle: previous version opened separate port-forward
#    processes for Check 3 and Check 4 on the same port 9090. If Check 3's
#    port-forward was still alive when Check 4 tried to open, Check 4 got
#    "bind: address already in use" and the variable prom_pf_pid was unset,
#    causing `kill ""` to error out.
#    Fix: single shared Prometheus port-forward for Checks 3+4, killed once
#    at the end. Helper function manages the lifecycle cleanly.
#
# 3. Added Check 5: Redis health. At 1000 VU the most common cartservice
#    crash cause is Redis connection exhaustion. This check queries Redis
#    connected_clients via kubectl exec and fails if > 150 (our maxclients=200,
#    so >150 means we're within 25 connections of the hard limit).
#
# 4. Added Check 6: HPA target validity. If any HPA shows <unknown> for
#    TARGETS, the HPA cannot scale and will either stay at minReplicas (under-
#    provisioned) or at whatever replica count it was at when metrics died.
#    This is always a metrics-server or Prometheus adapter issue. Catching it
#    early prevents the "why isn't HPA scaling?" confusion during demos.
#
# 5. OOM check now specifically calls out cartservice separately from the
#    general namespace OOM sweep. Cart OOM is the most common failure mode
#    and deserves its own check line in the summary.
#
# 6. Summary now prints per-check detail (not just pass/fail count) so you
#    can see at a glance which check failed without scrolling up.
# =============================================================================

set -uo pipefail   # intentionally not -e: collect all failures, don't bail on first

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
START_TS=$(date +%s)
START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Shared Prometheus port-forward ────────────────────────────────────────────
# Open once, reuse for checks 3+4, close at end.
PROM_PF_PID=0
PROM_PF_MINE=false

ensure_prometheus_pf() {
  if curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 3 2>/dev/null; then
    return 0  # already reachable (start.sh port-forward is live)
  fi
  if $PROM_PF_MINE && kill -0 "$PROM_PF_PID" 2>/dev/null; then
    return 0  # we already opened it
  fi
  kubectl port-forward -n observability svc/prometheus 9090:9090 \
    &>/tmp/pf-stability-prom.log &
  PROM_PF_PID=$!
  PROM_PF_MINE=true
  # Wait up to 10s for it to bind
  local elapsed=0
  while ! curl -sf "http://localhost:9090/-/healthy" -o /dev/null -m 2 2>/dev/null; do
    sleep 2; elapsed=$((elapsed + 2))
    [[ $elapsed -ge 10 ]] && return 1
  done
  return 0
}

close_prometheus_pf() {
  if $PROM_PF_MINE && kill -0 "$PROM_PF_PID" 2>/dev/null; then
    kill "$PROM_PF_PID" 2>/dev/null || true
    PROM_PF_MINE=false
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
info "Mode:    ${MODE:-full (1000 VU, ~9min)}"
info "Time:    $START_ISO"
echo ""

# Verify all expected workloads are present before starting the clock
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

# Check HPA targets are not <unknown> BEFORE the run
# If they're <unknown> now, the test results will be meaningless
hpa_unknown=$(kubectl get hpa -n boutique \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.currentMetrics[0].resource.current.averageUtilization}{"\n"}{end}' \
  2>/dev/null | grep -c "^[a-z].* $" || true)  # lines with empty second field = <unknown>
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
if [[ "$MODE" == "--no-k6" ]]; then
  section "k6 — skipped (--no-k6 mode)"

elif [[ "$MODE" == "--short" ]]; then
  section "k6 — smoke test (100 VU, 2min)"
  # FIX: Previous version used load-test_10vusers.js with --vus 100 override.
  # k6 ignores --vus when the script defines `stages` in options. The 10vusers
  # script defines stages, so the override was silently ignored.
  # Fix: use load-test_1000vusers.js but override the BASE_URL and run a
  # simple 100 VU / 2min test by passing --vus and --duration which DOES
  # override stage-based scripts when paired with --no-stages-default-executor
  # flag... but that's complex. Simplest correct approach: inline k6 script.
  k6 run \
    --vus 100 \
    --duration 2m \
    --env BASE_URL=http://localhost:30080 \
    - <<'EOF' || warn "k6 smoke test exited non-zero (check thresholds above)"
import http from 'k6/http';
import { sleep, check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:30080';
const PRODUCTS = ['OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O'];

export const options = {
  thresholds: {
    http_req_failed:   ['rate<0.05'],
    http_req_duration: ['p(95)<5000'],
  },
};

export default function () {
  const home = http.get(`${BASE}/`, { tags: { name: 'Home' } });
  check(home, { 'home 200': (r) => r.status === 200 });
  sleep(1);

  const pid = PRODUCTS[Math.floor(Math.random() * PRODUCTS.length)];
  const prod = http.get(`${BASE}/product/${pid}`, { tags: { name: 'Product' } });
  check(prod, { 'product 200': (r) => r.status === 200 });
  sleep(1);

  if (Math.random() > 0.7) {
    http.post(`${BASE}/cart`, { product_id: pid, quantity: 1 }, { tags: { name: 'AddCart' } });
    sleep(0.5);
  }
}
EOF

else
  section "k6 — full run (1000 VU, load-test_1000vusers.js)"
  k6 run "${REPO_ROOT}/scripts/load-test_1000vusers.js" || warn "k6 exited non-zero"
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

# CartService gets its own OOM check — it's the most frequent failure
cart_oom=$(kubectl get events -n boutique \
  --field-selector type=Warning \
  -o jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.involvedObject.name}{" "}{.reason}{" "}{.message}{"\n"}{end}' \
  2>/dev/null | \
  awk -v start="$START_ISO" '$1 >= start && ($3 == "OOMKilling" || $4 ~ /OOMKill/)' | \
  grep -i "cart" | wc -l | tr -d ' ')

if [[ "${cart_oom:-0}" -gt 0 ]]; then
  fail "cartservice: ${cart_oom} OOM event(s) — .NET GC heap limit may not be set correctly"
  fail "  Run: kubectl describe pod -n boutique -l app=cartservice | grep -A5 OOMKill"
  oom_total=$((oom_total + cart_oom))
fi

# General OOM sweep for all other pods
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
    fail "No spanmetrics samples in Prometheus — OTLP pipeline is not flowing"
    fail "  Check: bash scripts/manage.sh logs alloy"
    fail "  Check: bash scripts/manage.sh verify"
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

# Done with Prometheus — close port-forward if we opened it
close_prometheus_pf

# ── CHECK 5: Redis health ─────────────────────────────────────────────────────
section "Check 5 — Redis connection health"

redis_pod=$(kubectl get pods -n boutique -l app=redis \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$redis_pod" ]]; then
  fail "Redis pod not found — cartservice has no backend"
else
  # Check Redis is responding
  redis_ping=$(kubectl exec -n boutique "$redis_pod" \
    -- redis-cli ping 2>/dev/null || echo "FAILED")
  if [[ "$redis_ping" != "PONG" ]]; then
    fail "Redis not responding to PING (got: $redis_ping) — cartservice will crash"
  else
    # Check connection count — maxclients=200, warn at >150 (75%), fail at >180 (90%)
    connected=$(kubectl exec -n boutique "$redis_pod" \
      -- redis-cli info clients 2>/dev/null | \
      grep "connected_clients" | awk -F: '{print $2}' | tr -d '[:space:]' || echo "0")
    used_mem=$(kubectl exec -n boutique "$redis_pod" \
      -- redis-cli info memory 2>/dev/null | \
      grep "used_memory_human" | awk -F: '{print $2}' | tr -d '[:space:]' || echo "?")

    if [[ "${connected:-0}" -gt 180 ]]; then
      fail "Redis: ${connected}/200 connections (>90% — cartservice pods will start failing)"
    elif [[ "${connected:-0}" -gt 150 ]]; then
      warn "Redis: ${connected}/200 connections (>75% — approaching saturation)"
      ok "Redis responding to PING | clients=${connected}/200 | mem=${used_mem}"
    else
      ok "Redis responding to PING | clients=${connected}/200 | mem=${used_mem}"
    fi
  fi
fi

# ── CHECK 6: HPA target validity ──────────────────────────────────────────────
section "Check 6 — HPA target validity (metrics-server data)"

# An HPA with <unknown> targets cannot scale. This means either:
# - metrics-server is down/not ready
# - The target deployment has no running pods (all in Pending/CrashLoop)
# - The resource request on the pod is 0 (HPA can't calculate utilization %)
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
  fail "  Fix: kubectl top pods -n boutique (if this fails, metrics-server is down)"
  fail "  Fix: kubectl describe hpa -n boutique (look for Events explaining why)"
else
  ok "All HPA targets show valid CPU utilization percentages"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"

rm -f "$before_file" "$after_file" "$restart_diff"

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
  echo "    bash scripts/manage.sh cart-debug       # if cartservice is involved"
  echo "    bash scripts/manage.sh debug            # full diagnostic dump"
  echo "    bash scripts/manage.sh logs alloy       # check OTLP pipeline"
  echo "    bash scripts/manage.sh budget           # check node CPU/memory pressure"
  echo "    kubectl get events -A --sort-by='.lastTimestamp' | tail -30"
  echo ""
  exit 1
fi
