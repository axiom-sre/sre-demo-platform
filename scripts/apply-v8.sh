#!/usr/bin/env bash
# apply-v8.sh — Apply all v8 fixes in the correct order
# =============================================================================
# Run this from your sre-demo repo root.
# Each step has a verification command. Don't proceed until verification passes.
# =============================================================================

set -euo pipefail

echo "=== SRE Demo v8 Fix: HPA + GOMAXPROCS + In-cluster k6 ==="
echo ""

# ─── STEP 1: Apply HPA fixes ──────────────────────────────────────────────────
echo "[1/5] Applying HPA v5..."
kubectl apply -f boutique/hpa.yaml

echo ""
echo "  Verify HPAs updated:"
echo "  kubectl get hpa -n boutique"
echo "  Expected: frontend minReplicas=3, checkout minReplicas=4, currency minReplicas=4"
echo ""
kubectl get hpa -n boutique
echo ""

# ─── STEP 2: Apply boutique patches ───────────────────────────────────────────
echo "[2/5] Applying boutique patches (currency limit, GOMAXPROCS, checkout replicas)..."
# Note: boutique-patches-v8.yaml uses strategic merge patch
# For full apply, merge changes into boutique.yaml and apply the full file
kubectl apply -f boutique/boutique.yaml

echo ""
echo "  Verify rollout completes:"
kubectl rollout status deployment/frontend -n boutique --timeout=120s
kubectl rollout status deployment/currencyservice -n boutique --timeout=120s
kubectl rollout status deployment/checkoutservice -n boutique --timeout=120s
echo ""

# ─── STEP 3: Verify GOMAXPROCS set on frontend ───────────────────────────────
echo "[3/5] Verifying GOMAXPROCS on frontend pods..."
FRONTEND_POD=$(kubectl get pods -n boutique -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n boutique "$FRONTEND_POD" -- env | grep GOMAXPROCS || echo "  WARNING: GOMAXPROCS not set — check boutique.yaml env section"
echo ""

# ─── STEP 4: Verify currency CPU limit raised ────────────────────────────────
echo "[4/5] Verifying currency CPU limit..."
kubectl get deployment currencyservice -n boutique -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}'
echo " (expected: 300m)"
echo ""

# ─── STEP 5: Verify pod counts ───────────────────────────────────────────────
echo "[5/5] Current pod counts (waiting for min replicas to stabilize)..."
kubectl get pods -n boutique | grep -E "NAME|frontend|checkout|currency"
echo ""
echo "  Expected pod counts at idle:"
echo "  frontend:       3 pods (was 2)"
echo "  checkoutservice: 4 pods (was 2)"
echo "  currencyservice: 4 pods (was 2)"
echo ""

# ─── HOW TO RUN LOAD TEST IN-CLUSTER ─────────────────────────────────────────
echo "=== To run in-cluster load test (bypasses Docker Desktop NAT): ==="
echo ""
echo "  # Apply the k6 job manifest:"
echo "  kubectl apply -f scripts/k6-job-1000vu.yaml"
echo ""
echo "  # Watch k6 logs:"
echo "  kubectl logs -f job/k6-1000vu -n boutique"
echo ""
echo "  # Watch HPA scaling in parallel (new terminal):"
echo "  kubectl get hpa -n boutique -w"
echo ""
echo "  # Watch pods scaling in parallel (new terminal):"
echo "  kubectl get pods -n boutique -w | grep -v Running"
echo ""
echo "  # Expected: throughput 400-800 req/s vs old 55-73 req/s (NAT removed)"
echo "  # Expected: HPA fires for frontend within 90s of ramp start"
echo "  # Expected: HPA fires for currency within 60s (4 warm → scale to 8+)"
echo ""

# ─── QUICK HPA DEBUG COMMANDS ────────────────────────────────────────────────
echo "=== HPA Debug Commands ==="
echo ""
echo "  # Why isn't HPA firing? Check the conditions:"
echo "  kubectl describe hpa frontend -n boutique | grep -A5 Conditions"
echo ""
echo "  # Check metrics server has data:"
echo "  kubectl top pods -n boutique"
echo ""
echo "  # Check actual CPU vs request for HPA math:"
echo "  # HPA sees: (actual_cpu_sum / request_sum) × 100 = utilization%"
echo "  # If actual=40m, request=50m, pods=2: (40m×2)/(50m×2) = 80% → SHOULD fire at 50%"
echo "  # If it's not firing, check events:"
echo "  kubectl get events -n boutique --sort-by='.lastTimestamp' | grep -i hpa | tail -20"
echo ""
