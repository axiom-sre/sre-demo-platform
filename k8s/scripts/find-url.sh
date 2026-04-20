#!/usr/bin/env bash
# =============================================================================
# scripts/find-url.sh — Find the correct frontend URL on Docker Desktop
# =============================================================================
# Docker Desktop NodePort behaviour is inconsistent across versions.
# This script finds whatever actually works and prints the correct BASE_URL
# to use for k6 load tests.
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

# ── Step 2: Get auxiliary port info (for fallback candidates only) ────────────
node_port=$(kubectl get svc frontend -n boutique \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
svc_type=$(kubectl get svc frontend -n boutique \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo "unknown")
log "Service type: ${svc_type}  nodePort: ${node_port:-none}"

# ── Step 3: Try candidate URLs in order of preference ────────────────────────
# Priority order for Docker Desktop on macOS:
#   1. LoadBalancer port 8080 — Docker Desktop maps this to localhost natively ✓
#   2. Port-forward on 8080   — always works when start.sh is running ✓
#   3. NodePort localhost      — unreliable on Docker Desktop macOS
#   4. Node internal IP        — works for kind, some Docker Desktop configs

CANDIDATES=()

# 1. LoadBalancer port 8080 — Docker Desktop maps this to localhost:8080 natively.
#    This is the PREFERRED path (Docker Desktop LoadBalancer > NodePort).
CANDIDATES+=("http://localhost:8080")

# 2. NodePort via localhost (works on some Docker Desktop versions)
[[ -n "$node_port" ]] && CANDIDATES+=("http://localhost:${node_port}")
[[ -n "$node_port" ]] && CANDIDATES+=("http://127.0.0.1:${node_port}")

# 3. Node internal IP + NodePort (kind clusters, some Docker Desktop configs)
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
[[ -n "$node_ip" && -n "$node_port" ]] && CANDIDATES+=("http://${node_ip}:${node_port}")

WORKING_URL=""
for url in "${CANDIDATES[@]}"; do
  log "Trying: $url ..."
  http_code=$(curl -sf "$url/" -o /dev/null -w "%{http_code}" -m 5 2>/dev/null || echo "000")
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

  # ── Step 4: Confirm service type and routing ──────────────────────────────
  if [[ "$svc_type" == "LoadBalancer" ]]; then
    log "Service type: LoadBalancer ✓  (Docker Desktop routes this to localhost directly)"
  elif [[ -n "$node_port" && "$WORKING_URL" == *"8080"* && "$WORKING_URL" != *"${node_port}"* ]]; then
    log "Routing via port-forward on 8080 ✓  (LoadBalancer or port-forward active)"
  fi
fi
