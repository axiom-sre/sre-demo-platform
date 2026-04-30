#!/usr/bin/env bash
# =============================================================================
# k6-run.sh — In-cluster k6 job launcher
# =============================================================================
# Generates a ConfigMap + batch/v1 Job on the fly from CLI params and applies
# them to the cluster. No static YAML to maintain — the script IS the source
# of truth for both the load shape and the k6 script.
#
# USAGE:
#   bash k8s/scripts/k6-run.sh [flags]
#   bash k8s/scripts/k6-run.sh logs        # tail latest job
#   bash k8s/scripts/k6-run.sh status      # show all k6 jobs
#   bash k8s/scripts/k6-run.sh stop        # delete running job
#   bash k8s/scripts/k6-run.sh clean       # delete job + configmap
#
# LOAD SHAPE FLAGS:
#   --vus N          Peak VUs                        (default: 100)
#   --ramp-up DUR    Ramp to peak, e.g. 2m, 5m       (default: 2m)
#   --hold DUR       Hold at peak, e.g. 10m, 30m     (default: 10m)
#   --ramp-down DUR  Ramp to zero                    (default: 2m)
#   --spike-vus N    Mid-test spike VUs, 0=off       (default: 0)
#   --spike-dur DUR  Spike hold duration             (default: 1m)
#   --stepped        Use stepped ramp (250→500→...→peak) instead of linear
#   --p95 N          p95 SLA override in ms          (default: auto)
#
# EXAMPLES:
#   # Smoke — 10 VU, quick check
#   bash k8s/scripts/k6-run.sh --vus 10 --ramp-up 30s --hold 3m --ramp-down 30s
#
#   # Standard capacity run to 2K
#   bash k8s/scripts/k6-run.sh --vus 2000 --ramp-up 5m --hold 20m --ramp-down 3m
#
#   # Stepped staircase to 3K (SRE demo money shot)
#   bash k8s/scripts/k6-run.sh --vus 3000 --stepped --hold 5m
#
#   # Spike test: baseline 1K, spike to 2K mid-test
#   bash k8s/scripts/k6-run.sh --vus 1000 --hold 10m --spike-vus 2000 --spike-dur 2m
#
# MONITOR:
#   bash k8s/scripts/k6-run.sh logs     # live k6 output
#   bash k8s/scripts/k6-run.sh status   # job phase + pod state
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="boutique"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLU}info  $*${NC}"; }
ok()    { echo -e "${GRN}ok    $*${NC}"; }
warn()  { echo -e "${YLW}warn  $*${NC}"; }
error() { echo -e "${RED}err   $*${NC}"; exit 1; }
sep()   { echo -e "\n${BOLD}------ $* ------${NC}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
VUS=100
RAMP_UP="2m"
HOLD="10m"
RAMP_DOWN="2m"
SPIKE_VUS=0
SPIKE_DUR="1m"
STEPPED=false
P95_OVERRIDE=0

# ── Dispatch non-run commands ─────────────────────────────────────────────────
case "${1:-run}" in
  logs)
    JOB=$(kubectl get jobs -n "$NS" -l app=k6 \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    [[ -z "$JOB" ]] && error "No k6 jobs found in $NS"
    info "Tailing logs for job: $JOB"
    kubectl logs -n "$NS" -l "job-name=$JOB" -f --prefix
    exit 0 ;;
  status)
    echo ""
    kubectl get jobs -n "$NS" -l app=k6 \
      -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[0].type,START:.status.startTime,COMPLETE:.status.completionTime" \
      2>/dev/null || warn "No k6 jobs found"
    echo ""
    kubectl get pods -n "$NS" -l app=k6 \
      --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -10
    exit 0 ;;
  stop)
    JOBS=$(kubectl get jobs -n "$NS" -l app=k6 \
      --field-selector=status.active=1 \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    [[ -z "$JOBS" ]] && { warn "No active k6 jobs"; exit 0; }
    for j in $JOBS; do
      kubectl delete job "$j" -n "$NS" && ok "Deleted job: $j"
    done
    exit 0 ;;
  clean)
    kubectl delete job -n "$NS" -l app=k6 --ignore-not-found
    kubectl delete configmap k6-script -n "$NS" --ignore-not-found
    ok "Cleaned k6 jobs and ConfigMap"
    exit 0 ;;
  run|--*)
    # fall through to run logic
    [[ "${1:-}" == "run" ]] && shift || true ;;
  *)
    echo ""
    echo -e "${BOLD}k6-run.sh — in-cluster k6 job launcher${NC}"
    echo ""
    echo "  Commands:  run (default) | logs | status | stop | clean"
    echo ""
    echo "  Run flags:"
    echo "    --vus N          Peak VUs (default: 500)"
    echo "    --ramp-up DUR    e.g. 1m, 5m (default: 2m)"
    echo "    --hold DUR       e.g. 10m, 30m (default: 10m)"
    echo "    --ramp-down DUR  (default: 2m)"
    echo "    --spike-vus N    Mid-test spike, 0=off (default: 0)"
    echo "    --spike-dur DUR  Spike duration (default: 1m)"
    echo "    --stepped        Stepped staircase ramp instead of linear"
    echo "    --p95 N          p95 SLA ms override (default: auto)"
    echo ""
    echo "  Examples:"
    echo "    bash k8s/scripts/k6-run.sh --vus 2000 --ramp-up 5m --hold 20m"
    echo "    bash k8s/scripts/k6-run.sh --vus 3000 --stepped --hold 5m"
    echo "    bash k8s/scripts/k6-run.sh --vus 1000 --spike-vus 2000 --spike-dur 2m"
    exit 0 ;;
esac

# ── Parse run flags ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vus)        VUS="$2";          shift 2 ;;
    --ramp-up)    RAMP_UP="$2";      shift 2 ;;
    --hold)       HOLD="$2";         shift 2 ;;
    --ramp-down)  RAMP_DOWN="$2";    shift 2 ;;
    --spike-vus)  SPIKE_VUS="$2";    shift 2 ;;
    --spike-dur)  SPIKE_DUR="$2";    shift 2 ;;
    --stepped)    STEPPED=true;      shift   ;;
    --p95)        P95_OVERRIDE="$2"; shift 2 ;;
    *) error "Unknown flag: $1" ;;
  esac
done

# ── Auto p95 SLA ──────────────────────────────────────────────────────────────
if [[ $P95_OVERRIDE -gt 0 ]]; then
  P95=$P95_OVERRIDE
elif [[ $VUS -le 10 ]]; then   P95=250
elif [[ $VUS -le 100 ]]; then  P95=500
elif [[ $VUS -le 500 ]]; then  P95=750
else                           P95=1000
fi

# ── Job name (unique per run) ─────────────────────────────────────────────────
SLUG=$(echo "${VUS}-${RANDOM}" | shasum 2>/dev/null | cut -c1-6 \
       || echo "${RANDOM}${RANDOM}" | cut -c1-6)
JOB_NAME="k6-${VUS}vu-${SLUG}"

# ── Build stages JSON ─────────────────────────────────────────────────────────
build_stages() {
  local stages=""

  if [[ "$STEPPED" == "true" ]]; then
    # Staircase: warmup → 25% → 50% → 75% → 100%, each held for HOLD
    local step=$(( VUS / 4 ))
    stages='{ duration: "1m", target: '"$step"' },'
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $step },"
    stages+=$'\n        '"{ duration: \"1m\", target: $(( step * 2 )) },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $(( step * 2 )) },"
    stages+=$'\n        '"{ duration: \"1m\", target: $(( step * 3 )) },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $(( step * 3 )) },"
    stages+=$'\n        '"{ duration: \"$RAMP_UP\", target: $VUS },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $VUS },"
  else
    # Linear ramp
    stages="{ duration: \"$RAMP_UP\", target: $VUS },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $VUS },"
  fi

  # Spike injection mid-test (only for linear mode)
  if [[ $SPIKE_VUS -gt 0 && "$STEPPED" == "false" ]]; then
    # Insert spike after first hold, then recover
    stages="{ duration: \"$RAMP_UP\", target: $VUS },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $VUS },"
    stages+=$'\n        '"{ duration: \"$SPIKE_DUR\", target: $SPIKE_VUS },"
    stages+=$'\n        '"{ duration: \"$SPIKE_DUR\", target: $VUS },"
    stages+=$'\n        '"{ duration: \"$HOLD\", target: $VUS },"
  fi

  stages+=$'\n        '"{ duration: \"$RAMP_DOWN\", target: 0 }"
  echo "$stages"
}

STAGES=$(build_stages)

# ── Print plan ────────────────────────────────────────────────────────────────
sep "k6 In-Cluster Job"
info "Job name  : $JOB_NAME"
info "Peak VUs  : $VUS"
info "Ramp up   : $RAMP_UP"
info "Hold      : $HOLD"
info "Ramp down : $RAMP_DOWN"
[[ $SPIKE_VUS -gt 0 ]] && info "Spike     : ${SPIKE_VUS} VU x ${SPIKE_DUR}"
[[ "$STEPPED" == "true" ]] && info "Mode      : stepped staircase"
info "p95 SLA   : ${P95}ms"
info "Namespace : $NS"

# ── Apply ConfigMap ───────────────────────────────────────────────────────────
sep "Applying k6-script ConfigMap"

kubectl apply -f - << CONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-script
  namespace: ${NS}
  labels:
    app: k6
    vus: "${VUS}"
data:
  load-test.js: |
    import http from 'k6/http';
    import { sleep, check, group } from 'k6';

    var BASE = __ENV.BASE_URL || 'http://frontend.boutique.svc.cluster.local:8080';
    var P95_SLA = ${P95};

    var P = { timeout: '60s', tags: { test: '${JOB_NAME}' } };

    var PRODUCTS = [
      'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O', '0PUK6V6EV0', '2ZYFJ3GM2N',
      'L9ECAV7KIM', 'LS4PSXUNUM', '9SIQT8TOJO', '6E92ZMYYFZ',
    ];

    export var options = {
      stages: [
        ${STAGES}
      ],
      thresholds: {
        http_req_failed:   ['rate<0.001'],
        http_req_duration: ['p(95)<' + P95_SLA],
      },
      summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
      tags: { test: '${JOB_NAME}' },
    };

    function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

    function thinkScaled(lo, hi) {
      var factor = ${VUS} > 500 ? 0.5 : ${VUS} > 100 ? 0.75 : 1.0;
      sleep(Math.random() * (hi - lo) * factor + lo * factor);
    }

    function windowShopper() {
      var home = http.get(BASE + '/', { timeout: P.timeout, tags: { name: 'Home', test: P.tags.test } });
      check(home, { 'home: 200': function(r) { return r.status === 200; } });
      thinkScaled(2, 5);
      for (var i = 0; i < 2; i++) {
        var prod = http.get(BASE + '/product/' + pick(PRODUCTS),
          { timeout: P.timeout, tags: { name: 'ProductPage', test: P.tags.test } });
        check(prod, {
          'product: 200':       function(r) { return r.status === 200; },
          'product: has price': function(r) { return r.body && r.body.indexOf('$') >= 0; },
        });
        thinkScaled(2, 5);
      }
    }

    function cartAbandoner() {
      windowShopper();
      var add = http.post(BASE + '/cart',
        { product_id: pick(PRODUCTS), quantity: '1' },
        { timeout: P.timeout, tags: { name: 'AddToCart', test: P.tags.test } });
      check(add, { 'addToCart: ok': function(r) { return r.status === 200 || r.status === 302; } });
      var cart = http.get(BASE + '/cart',
        { timeout: P.timeout, tags: { name: 'ViewCart', test: P.tags.test } });
      check(cart, { 'viewCart: 200': function(r) { return r.status === 200; } });
      thinkScaled(2, 5);
    }

    function powerBuyer() {
      cartAbandoner();
      var co = http.post(BASE + '/cart/checkout', {
        email: 'sre-load@example.com', street_address: '1 Load Lane',
        zip_code: '10001', city: 'LoadCity', state: 'CA', country: 'US',
        credit_card_number: '4432801561520454',
        credit_card_expiration_month: '1', credit_card_expiration_year: '2030',
        credit_card_cvv: '672',
      }, { timeout: P.timeout, tags: { name: 'Checkout', test: P.tags.test } });
      check(co, {
        'checkout: ok':     function(r) { return r.status === 200 || r.status === 302; },
        'checkout: no 5xx': function(r) { return r.status < 500; },
      });
      thinkScaled(2, 5);
    }

    export default function() {
      var roll = Math.random();
      group('session', function() {
        if (roll < 0.50)      windowShopper();
        else if (roll < 0.90) cartAbandoner();
        else                  powerBuyer();
      });
    }
CONFIGMAP

ok "ConfigMap applied"

# ── Apply Job ─────────────────────────────────────────────────────────────────
sep "Applying k6 Job"

kubectl apply -f - << JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS}
  labels:
    app: k6
    vus: "${VUS}"
    test: capacity
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app: k6
        job-name: ${JOB_NAME}
    spec:
      restartPolicy: Never
      priorityClassName: boutique-background
      containers:
        - name: k6
          image: grafana/k6:latest
          args: [run, /scripts/load-test.js]
          env:
            - name: BASE_URL
              value: "http://frontend.boutique.svc.cluster.local:8080"
            - name: K6_NO_COLOR
              value: "false"
          volumeMounts:
            - name: script
              mountPath: /scripts
          resources:
            requests:
              cpu:    "1000m"
              memory: "512Mi"
            limits:
              cpu:    "2000m"
              memory: "1Gi"
      volumes:
        - name: script
          configMap:
            name: k6-script
JOB

ok "Job created: $JOB_NAME"
echo ""
echo "  Live logs : kubectl logs -n $NS -l job-name=${JOB_NAME} -f"
echo "  Watch pod : kubectl get pods -n $NS -l app=k6 -w"
echo "  Stop      : bash k8s/scripts/k6-run.sh stop"
echo "  Status    : bash k8s/scripts/k6-run.sh status"
echo ""
info "Grafana: open 'k6 Load Test Controller' or Golden Signals dashboard"
