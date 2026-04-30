#!/usr/bin/env bash
# =============================================================================
# k6-stack.sh v3 — In-cluster k6 controller (operator-direct, no REST API)
# =============================================================================
# Drives the k6 Operator directly via kubectl apply of TestRun CRDs.
# No Python, no REST API, no port-forward needed to run tests.
#
# Usage:
#   bash k8s/scripts/k6-stack.sh up                         # install stack
#   bash k8s/scripts/k6-stack.sh run --vus 500 --hold 10m   # fire test
#   bash k8s/scripts/k6-stack.sh status                     # list TestRuns
#   bash k8s/scripts/k6-stack.sh logs                       # tail latest test
#   bash k8s/scripts/k6-stack.sh stop                       # kill all tests
#   bash k8s/scripts/k6-stack.sh down                       # teardown
#
# Run flag reference:
#   --vus N          Peak virtual users          (default: 100)
#   --ramp-up DUR    e.g. 30s, 1m, 5m           (default: 1m)
#   --hold DUR       e.g. 5m, 20m, 1h           (default: 5m)
#   --ramp-down DUR  e.g. 30s, 2m               (default: 30s)
#   --spike-vus N    Spike VUs mid-test, 0=off  (default: 0)
#   --spike-dur DUR  Spike hold duration        (default: 30s)
#
# Examples:
#   bash k8s/scripts/k6-stack.sh run --vus 1000 --ramp-up 5m --hold 20m --ramp-down 3m
#   bash k8s/scripts/k6-stack.sh run --vus 500 --hold 10m --spike-vus 1500 --spike-dur 1m
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K6_DIR="$REPO_ROOT/k8s/observability/k6"
TMPDIR_K6="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_K6"' EXIT

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLU}ℹ  $*${NC}"; }
ok()    { echo -e "${GRN}✓  $*${NC}"; }
warn()  { echo -e "${YLW}⚠  $*${NC}"; }
error() { echo -e "${RED}✗  $*${NC}"; exit 1; }
sep()   { echo -e "\n${BOLD}── $* ──────────────────────────────────${NC}"; }

# ── Auto p95 SLA ─────────────────────────────────────────────────────────────
auto_p95() {
  local vus=$1
  if   [[ $vus -le 10  ]]; then echo 250
  elif [[ $vus -le 100 ]]; then echo 500
  elif [[ $vus -le 500 ]]; then echo 750
  else echo 1000; fi
}

# ── Unique run name ───────────────────────────────────────────────────────────
run_name() {
  local vus=$1
  local hash
  hash=$(echo "${vus}-${RANDOM}-$(date +%s)" | shasum | cut -c1-6)
  echo "k6-${vus}vu-${hash}"
}

# ── Wait for deployment ───────────────────────────────────────────────────────
wait_deploy() {
  local name=$1 ns=$2 timeout=${3:-120}
  info "Waiting for $name ($ns) — timeout ${timeout}s…"
  kubectl rollout status deployment/"$name" -n "$ns" --timeout="${timeout}s" \
    && ok "$name ready" \
    || warn "$name not ready — check: kubectl get pods -n $ns"
}

# =============================================================================
# UP
# =============================================================================
cmd_up() {
  sep "1. k6 Operator (official Grafana bundle)"
  BUNDLE="$K6_DIR/bundle.yaml"

  # Download bundle if not present — commit bundle.yaml to your repo after first run
  if [[ ! -f "$BUNDLE" ]]; then
    info "Downloading official k6-operator bundle..."
    curl -sL https://raw.githubusercontent.com/grafana/k6-operator/main/bundle.yaml \
      -o "$BUNDLE" || error "Failed to download bundle — check internet connectivity"
    ok "Bundle saved to $BUNDLE (commit this file to your repo)"
  else
    info "Using cached bundle: $BUNDLE"
  fi

  kubectl apply -f "$BUNDLE"

  # Operator deploys into k6-operator-system namespace (not k6)
  info "Waiting for controller-manager..."
  sleep 5
  kubectl rollout status deployment/k6-operator-controller-manager \
    -n k6-operator-system --timeout=120s \
    && ok "k6-operator controller-manager running" \
    || warn "Operator slow — check: kubectl get pods -n k6-operator-system"

  # k6 test jobs run in the k6 namespace
  kubectl create namespace k6 --dry-run=client -o yaml | kubectl apply -f -

  sep "2. k6 Runner config (TestRun template + SA)"
  kubectl apply -f "$K6_DIR/k6-runner.yaml"
  ok "TestRun template and ServiceAccount applied"

  sep "3. Prometheus remote_write receiver"
  # Add --web.enable-remote-write-receiver to Prometheus if not already present
  CURRENT_ARGS=$(kubectl get deployment prometheus -n observability \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")
  if echo "$CURRENT_ARGS" | grep -q "remote-write-receiver"; then
    ok "Prometheus remote_write receiver already enabled"
  else
    # Use strategic merge patch — safe to re-apply, no duplicate args
    # This REPLACES the args array, so include all required flags
    kubectl patch deployment prometheus -n observability --type=strategic -p '{
      "spec": {"template": {"spec": {"containers": [{
        "name": "prometheus",
        "args": [
          "--config.file=/etc/prometheus/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--storage.tsdb.retention.time=7d",
          "--web.console.libraries=/usr/share/prometheus/console_libraries",
          "--web.console.templates=/usr/share/prometheus/consoles",
          "--web.enable-remote-write-receiver",
          "--web.enable-lifecycle"
        ]
      }]}}}}' && ok "Prometheus patched with remote_write receiver" \
      || warn "Prometheus patch failed — check prometheus.yaml args manually"
  fi

  sep "4. Grafana — Infinity plugin + k6 dashboard"
  # Install Infinity plugin if not present
  CURRENT_PLUGINS=$(kubectl get deployment grafana -n observability \
    -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | \
    grep -o 'yesoreyeram-infinity[^"]*' || echo "")
  if [[ -z "$CURRENT_PLUGINS" ]]; then
    kubectl set env deployment/grafana -n observability \
      GF_INSTALL_PLUGINS="yesoreyeram-infinity-datasource" \
      && ok "Infinity plugin env set" \
      || warn "Could not set plugin env — add GF_INSTALL_PLUGINS to grafana.yaml manually"
  else
    ok "Infinity plugin already configured"
  fi

  kubectl apply -f "$K6_DIR/k6-grafana-dashboard.yaml"

  # Bounce Grafana (scale-to-zero pattern to avoid PVC write-lock)
  info "Bouncing Grafana to load new dashboard…"
  kubectl scale deployment grafana -n observability --replicas=0
  kubectl wait --for=delete pod -l app=grafana -n observability --timeout=30s 2>/dev/null || true
  kubectl scale deployment grafana -n observability --replicas=1
  wait_deploy grafana observability 120

  sep "5. Verify"
  kubectl get pods -n k6
  echo ""
  ok "k6 stack is up!"
  echo ""
  echo "  Fire a test:    bash k8s/scripts/k6-stack.sh run --vus 100 --hold 5m"
  echo "  Watch status:   bash k8s/scripts/k6-stack.sh status"
  echo "  Tail logs:      bash k8s/scripts/k6-stack.sh logs"
  echo "  Grafana:        open 'k6 Load Test Controller' dashboard"
}

# =============================================================================
# RUN — generate and apply a TestRun CRD
# =============================================================================
cmd_run() {
  # Defaults
  local VUS=100 RAMP_UP="1m" HOLD="5m" RAMP_DOWN="30s"
  local SPIKE_VUS=0 SPIKE_DUR="30s"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vus)        VUS="$2";       shift 2 ;;
      --ramp-up)    RAMP_UP="$2";   shift 2 ;;
      --hold)       HOLD="$2";      shift 2 ;;
      --ramp-down)  RAMP_DOWN="$2"; shift 2 ;;
      --spike-vus)  SPIKE_VUS="$2"; shift 2 ;;
      --spike-dur)  SPIKE_DUR="$2"; shift 2 ;;
      *) error "Unknown flag: $1 (valid: --vus --ramp-up --hold --ramp-down --spike-vus --spike-dur)" ;;
    esac
  done

  local P95_SLA
  P95_SLA=$(auto_p95 "$VUS")
  local NAME
  NAME=$(run_name "$VUS")

  # Check operator is up
  if ! kubectl get deployment k6-operator-controller-manager -n k6-operator-system &>/dev/null; then
    error "k6-operator not installed — run: bash k8s/scripts/k6-stack.sh up"
  fi
  if ! kubectl rollout status deployment/k6-operator-controller-manager       -n k6-operator-system --timeout=10s &>/dev/null; then
    warn "k6-operator not fully ready but proceeding..."
  fi

  sep "Firing k6 TestRun"
  info "Name      : $NAME"
  info "Peak VUs  : $VUS"
  info "Ramp up   : $RAMP_UP"
  info "Hold      : $HOLD"
  info "Ramp down : $RAMP_DOWN"
  info "p95 SLA   : ${P95_SLA}ms (auto)"
  [[ $SPIKE_VUS -gt 0 ]] && info "Spike     : ${SPIKE_VUS} VU for ${SPIKE_DUR}"

  # Build TestRun manifest from template
  local MANIFEST="$TMPDIR_K6/${NAME}.yaml"
  local TEMPLATE="$K6_DIR/k6-runner.yaml"

  # Extract the testrun.yaml section from the ConfigMap data and substitute
  # We generate it directly here so we don't depend on the template CM being
  # readable from disk at runtime
  cat > "$MANIFEST" << TESTRUN
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: ${NAME}
  namespace: k6
  labels:
    app: k6-load-test
    vus: "${VUS}"
    triggered-by: k6-stack
  annotations:
    k6.io/vus: "${VUS}"
    k6.io/ramp-up: "${RAMP_UP}"
    k6.io/hold: "${HOLD}"
    k6.io/ramp-down: "${RAMP_DOWN}"
    k6.io/started-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
  parallelism: 1
  script:
    configMap:
      name: k6-script
      file: load-test.js
  arguments: >-
    -e VUS=${VUS}
    -e RAMP_UP=${RAMP_UP}
    -e HOLD=${HOLD}
    -e RAMP_DOWN=${RAMP_DOWN}
    -e SPIKE_VUS=${SPIKE_VUS}
    -e SPIKE_DUR=${SPIKE_DUR}
    -e P95_SLA=${P95_SLA}
    -e BASE_URL=http://frontend.boutique.svc.cluster.local:80
    --out experimental-prometheus-rw
  runner:
    image: grafana/k6:0.52.0
    env:
      - name: K6_PROMETHEUS_RW_SERVER_URL
        value: "http://prometheus.observability.svc.cluster.local:9090/api/v1/write"
      - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
        value: "true"
      - name: K6_PROMETHEUS_RW_PUSH_INTERVAL
        value: "5s"
    resources:
      requests:
        cpu: "500m"
        memory: "256Mi"
      limits:
        cpu: "2000m"
        memory: "1Gi"
TESTRUN

  kubectl apply -f "$MANIFEST"
  ok "TestRun created: $NAME"
  echo ""
  echo "  Live logs:    kubectl logs -n k6 -l job-name=${NAME} -f --prefix"
  echo "  Watch pods:   kubectl get pods -n k6 -w"
  echo "  Get status:   kubectl get testrun ${NAME} -n k6"
  echo "  Stop this:    kubectl delete testrun ${NAME} -n k6"
  echo ""
  info "Prometheus remote_write → Grafana panels update every 5s"
  info "Open: 'k6 Load Test Controller' dashboard in Grafana"
}

# =============================================================================
# STATUS
# =============================================================================
cmd_status() {
  echo ""
  sep "TestRuns"
  kubectl get testruns -n k6 \
    -o custom-columns="NAME:.metadata.name,STAGE:.status.stage,VUS:.metadata.labels.vus,STARTED:.metadata.annotations['k6\.io/started-at'],AGE:.metadata.creationTimestamp" \
    2>/dev/null || warn "No TestRuns found"

  echo ""
  sep "k6 Pods"
  kubectl get pods -n k6 \
    --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -15
}

# =============================================================================
# LOGS — tail the most recent running k6 test pod
# =============================================================================
cmd_logs() {
  # Find newest non-operator pod
  local POD
  POD=$(kubectl get pods -n k6 \
    --sort-by=.metadata.creationTimestamp \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$POD" ]]; then
    # Try completed pods too
    POD=$(kubectl get pods -n k6 \
      --sort-by=.metadata.creationTimestamp \
      -l app=k6-load-test \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
  fi

  if [[ -z "$POD" ]]; then
    warn "No k6 test pods found"
    info "Operator logs:"
    kubectl logs -n k6-operator-system deploy/k6-operator-controller-manager --tail=20
    return
  fi

  info "Tailing $POD (Ctrl+C to stop)"
  kubectl logs -n k6 "$POD" -f
}

# =============================================================================
# STOP
# =============================================================================
cmd_stop() {
  local COUNT
  COUNT=$(kubectl get testruns -n k6 --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$COUNT" -eq 0 ]]; then
    warn "No TestRuns running"
    return
  fi
  kubectl delete testruns --all -n k6
  ok "Deleted $COUNT TestRun(s)"
}

# =============================================================================
# DOWN
# =============================================================================
cmd_down() {
  sep "Stopping all TestRuns"
  kubectl delete testruns --all -n k6 2>/dev/null || true
  sep "Removing k6 Operator"
  BUNDLE="$K6_DIR/bundle.yaml"
  if [[ -f "$BUNDLE" ]]; then
    kubectl delete -f "$BUNDLE" --ignore-not-found 2>/dev/null || true
  fi
  kubectl delete -f "$K6_DIR/k6-runner.yaml" --ignore-not-found 2>/dev/null || true
  ok "k6 stack removed"
}

# =============================================================================
# Dispatch
# =============================================================================
CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  up)     cmd_up                    ;;
  run)    cmd_run "$@"              ;;
  status) cmd_status                ;;
  logs)   cmd_logs                  ;;
  stop)   cmd_stop                  ;;
  down)   cmd_down                  ;;
  help|*)
    echo ""
    echo -e "${BOLD}k6-stack.sh v3 — in-cluster k6 controller${NC}"
    echo ""
    echo "  Commands:"
    echo "    up                     Install k6 operator + Grafana dashboard"
    echo "    run [flags]            Fire a k6 TestRun via the Operator"
    echo "    status                 Show all TestRuns and pods"
    echo "    logs                   Tail latest running k6 pod"
    echo "    stop                   Delete all running TestRuns"
    echo "    down                   Teardown k6 stack"
    echo ""
    echo "  Run flags:"
    echo "    --vus N          Peak VUs           (default: 100)"
    echo "    --ramp-up DUR    e.g. 30s, 1m, 5m  (default: 1m)"
    echo "    --hold DUR       e.g. 5m, 20m, 1h  (default: 5m)"
    echo "    --ramp-down DUR  e.g. 30s, 2m       (default: 30s)"
    echo "    --spike-vus N    Spike VUs (0=off)  (default: 0)"
    echo "    --spike-dur DUR  Spike duration     (default: 30s)"
    echo ""
    echo "  Examples:"
    echo "    bash k8s/scripts/k6-stack.sh run --vus 1000 --ramp-up 5m --hold 20m"
    echo "    bash k8s/scripts/k6-stack.sh run --vus 500 --spike-vus 1500 --spike-dur 1m"
    echo ""
    ;;
esac
