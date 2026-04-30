#!/usr/bin/env bash
# =============================================================================
# scripts/find-url.sh — Find the correct frontend URL v3
# =============================================================================
# Docker Desktop LoadBalancer → localhost:8080 is the primary reliable path.
# NodePort :30080 is secondary — works on some Docker Desktop versions but
# breaks after sleep/wake due to VM network namespace reset.
#
# KEY CHANGES vs v2:
#
# 1. Health check URL changed from / to /_healthz.
#    The root path / renders the full boutique homepage (calls productcatalog,
#    currency, ads — 5+ gRPC calls). During cold-start, / returns 500 even
#    when the HTTP server is up. /_healthz is a lightweight internal check
#    that only verifies the HTTP server, not backends — correct for URL discovery.
#    Note: for smoke testing we still hit / to verify backends are ready.
#
# 2. HTTP 200 OR 302 both count as reachable.
#    Some Docker Desktop versions add a redirect on first hit. 302 is fine.
#    Previous version only accepted 200 — missed working endpoints on redirect.
#
# Usage:
#   bash scripts/find-url.sh
#   export BASE_URL=$(bash scripts/find-url.sh --export)
#   k6 run --env BASE_URL=$(bash scripts/find-url.sh --export) scripts/load-test_10vusers.js
# =============================================================================

set -uo pipefail

EXPORT_MODE="${1:-}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()  { [[ "$EXPORT_MODE" != "--export" ]] && echo -e "${GREEN}▶${NC} $*" >&2; }
warn() { [[ "$EXPORT_MODE" != "--export" ]] && echo -e "${YELLOW}⚠${NC}  $*" >&2; }
err()  { [[ "$EXPORT_MODE" != "--export" ]] && echo -e "${RED}✗${NC}  $*" >&2; }

# ── Step 1: Check the pod is actually running ─────────────────────────────────
log "Checking frontend pod status..."
pod_status=$(kubectl get pods -n boutique -l app=frontend \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

if [[ "$pod_status" != "Running" ]]; then
  err "Frontend pod is not Running (status: $pod_status)"
  err "Fix: bash scripts/start.sh  OR  kubectl rollout restart deployment/frontend -n boutique"
  exit 1
fi
log "Frontend pod: Running ✓"

# ── Step 2: Get service info ──────────────────────────────────────────────────
node_port=$(kubectl get svc frontend -n boutique \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
svc_type=$(kubectl get svc frontend -n boutique \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo "unknown")
log "Service type: ${svc_type}  nodePort: ${node_port:-none}"

# ── Step 3: Try candidate URLs ────────────────────────────────────────────────
# Priority order:
#   1. LoadBalancer :8080 — Docker Desktop maps this natively to localhost ✓
#   2. Port-forward :8080 — always works when start.sh is running ✓
#   3. NodePort via localhost — unreliable on Docker Desktop macOS
#   4. Node internal IP + NodePort — works for Kind, some Docker Desktop configs

CANDIDATES=()
CANDIDATES+=("http://localhost:8080")
[[ -n "$node_port" ]] && CANDIDATES+=("http://localhost:${node_port}")
[[ -n "$node_port" ]] && CANDIDATES+=("http://127.0.0.1:${node_port}")
node_ip=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "")
[[ -n "$node_ip" && -n "$node_port" ]] && CANDIDATES+=("http://${node_ip}:${node_port}")

WORKING_URL=""
for url in "${CANDIDATES[@]}"; do
  log "Trying: $url ..."
  # Use /_healthz (not /) — faster, works during backend cold-start
  http_code=$(curl -sf "${url}/_healthz" -o /dev/null \
    -w "%{http_code}" -m 5 \
    -H "Cookie: shop_session-id=x-find-url" \
    2>/dev/null || echo "000")
  if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
    log "✓ Reachable at $url (HTTP $http_code)"
    WORKING_URL="$url"
    break
  else
    warn "  → HTTP $http_code (not reachable)"
  fi
done

if [[ -z "$WORKING_URL" ]]; then
  err "Frontend not reachable on any candidate URL."
  err ""
  err "Likely causes:"
  err "  1. Frontend pod is starting up — wait 60s and retry"
  err "     (minReadySeconds=30 means the pod waits 30s after readiness probe)"
  err "  2. Docker Desktop NodePort not bound — restart Docker Desktop"
  err "  3. Port-forward not running — run: bash scripts/start.sh --pf-only"
  err ""
  err "Quick fix: start a port-forward manually:"
  err "  kubectl port-forward -n boutique svc/frontend 8080:8080 &"
  err "  Then run k6 with: --env BASE_URL=http://localhost:8080"
  exit 1
fi

if [[ "$EXPORT_MODE" == "--export" ]]; then
  echo "$WORKING_URL"
else
  echo ""
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  echo -e "${GREEN} USE THIS URL FOR K6:${NC}"
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  echo ""
  echo "  $WORKING_URL"
  echo ""
  echo "  k6 run --env BASE_URL=$WORKING_URL scripts/load-test_10vusers.js"
  echo "  k6 run --env BASE_URL=$WORKING_URL scripts/load-test_100vusers.js"
  echo "  k6 run --env BASE_URL=$WORKING_URL scripts/load-test_1000vusers.js"
  echo ""
  if [[ "$svc_type" == "LoadBalancer" ]]; then
    log "Service type: LoadBalancer ✓  (Docker Desktop routes this to localhost directly)"
  fi
fi
