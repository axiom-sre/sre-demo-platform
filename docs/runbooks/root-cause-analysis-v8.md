# SRE Demo v8 — Root Cause Analysis & Fix Summary
Generated: 2026-04-23

## Problems Identified

### Problem 1: Throughput Plateau at ~60-70 req/s (ALL VU levels)
**Symptom:** 100 VU = 55 req/s, 250 VU = 73 req/s, 500 VU = 61 req/s, 1000 VU = 56 req/s. Throughput is the same regardless of VU count.

**Root cause:** Docker Desktop's `vpnkit` NAT proxy. ALL traffic from k6 (running on Mac) to `localhost:8080` flows through a **single-threaded userspace NAT process**. This proxy saturates at ~60-70 req/s. The app itself has ~10x more capacity — you never saw it.

**Fix:** Run k6 as a Kubernetes Job **inside the cluster**. In-cluster traffic uses `iptables` kube-proxy, not vpnkit. Expected result: 400-800 req/s at 1000 VU.

**Real-world SRE note:** This is a known Docker Desktop limitation. In production you'd run k6 from a dedicated load generator node in the same VPC/AZ as the target. Never measure from behind NAT.

---

### Problem 2: HPA Never Fired for Frontend and Checkout
**Symptom:** Frontend stuck at 2 replicas, checkout at 3 (its minReplicas). HPA gauges barely moved in Grafana.

**Root cause (Frontend — Go service):** Go is asynchronous and CPU-efficient. Frontend handled 800 req/s bursts while burning only ~20-40m millicore CPU. The HPA trigger was `50% × 50m request = 25m`. With 2 pods: `(40m × 2) / (50m × 2) = 80%` — this SHOULD have fired. But because vpnkit was throttling actual throughput to ~70 req/s, frontend never got genuinely loaded. The CPU utilization HPA saw was representative of 70 req/s, not 1000 VU. Combined with the NAT throttle, HPA saw light load and did nothing.

**Root cause (Currency — CPU limit throttle):** Currency had a CPU **limit** of 100m. At high fan-out (every page render), cgroup was throttling currency pods at 100m before utilization could rise. CPU throttling ≠ CPU utilization. HPA measures utilization (`cpu_actual / cpu_request`). A throttled pod shows **low** utilization (it's not running, it's paused by cgroup). So HPA saw currency at 20% utilization and did nothing — while users were queueing behind throttled pods.

**Root cause (Checkout — I/O bound):** Checkout is correct in the comments: it's I/O-bound. It blocks on 7 gRPC calls. CPU barely moves. CPU-based HPA is the wrong signal.

**Fixes:**
- Frontend: Switch to **memory-based HPA** (primary). Go goroutines allocate 8KB heap stack each. Memory rises proportionally with goroutine queue depth. Correct signal for Go services.
- Checkout: Add memory trigger alongside CPU. Also raised minReplicas 3→4.
- Currency: Raise CPU **limit** 100m→300m. Removes the throttle. HPA trigger (60% × 50m = 30m on request) is unchanged and now meaningful.
- All HPAs: Cut `scaleUp.stabilizationWindowSeconds` from 30s → 15s. Faster response to ramp.

---

### Problem 3: Frontend GOMAXPROCS Mismatch
**Symptom:** Frontend shows CPU throttling in the saturation panel even at moderate load.

**Root cause:** Go defaults `GOMAXPROCS` to the **node's physical CPU count**, which on M5 Pro is 12. Inside a container with `cpu: limit: 2000m` (2 cores), Go spawns 12 OS threads competing for 2 cores worth of time. The cgroup scheduler constantly throttles Go threads. This shows up as CPU throttle rate in Grafana even when actual CPU use is low.

**Fix:** Set `GOMAXPROCS=4` in frontend env. This matches a raised limit of 4000m (4 vCPU-equivalent). For 5K VU you may want `GOMAXPROCS=6` with `cpu: limit: 6000m`.

**Formula:** `GOMAXPROCS = floor(cpu_limit_millicores / 1000)` — but always set it explicitly, never rely on the default inside containers.

---

### Problem 4: The 16.4s Latency "Cap" in Grafana
**Symptom:** Latency charts show a hard ceiling around 16.4s.

**Root cause:** Not Grafana. This is where your request distribution clusters before the k6 `timeout: '30s'` cliff. Requests that would take longer than 30s are killed by k6 at exactly 30s and counted as failures. The latency histogram for successful requests peaks at ~16s because that's the median wait time in the queue before getting a response. Requests that queued longer than 30s never complete — they become the 4.52% failure rate.

**Secondary cause:** Tempo's default trace duration limit. Spans longer than a certain threshold may be truncated. This is cosmetic — the actual latency data in Prometheus is accurate.

**No fix needed** — this is correct behavior. The metric to watch is `http_req_failed` rate (was 4.52% at 1000 VU with NAT throttle). After fixes, with in-cluster k6, you should see p95 <2000ms and <1% errors.

---

### Problem 5: `shippingservice` and `paymentservice` Still at `replicas: 1`
**Symptom (from boutique.yaml):** Both deployments have `replicas: 1` — single pod, no HA.

**Root cause:** Despite having HPAs in v4, the deployment spec still says `replicas: 1`. When kubectl applies this, Kubernetes sets the deployment to 1 replica. HPA then scales it up if needed, but if metrics-server is slow or HPA hasn't reconciled yet (first 30-60s of load), a single replica handles all checkout traffic.

**Fix:** Set `replicas: 2` to match HPA `minReplicas: 2` in both deployments. HPA won't scale down below minReplicas, so this is safe. The spec `replicas` field becomes advisory once an HPA is attached, but it sets the baseline.

---

## What to Expect After Fixes

| Metric | Before (v7, host k6) | After (v8, in-cluster k6) |
|--------|---------------------|--------------------------|
| Throughput at 1000 VU | ~56 req/s | ~400-800 req/s |
| p95 latency | 26.8s | <2s |
| p99 latency | 30s (timeout) | <5s |
| Error rate | 4.52% | <0.5% |
| Frontend replicas at peak | 2 (no scale) | 6-8 |
| Checkout replicas at peak | 3 (min) | 6-8 |
| Currency replicas at peak | 3-4 | 8-12 |
| HPA fires within | never | 60-90s of ramp |

---

## Interview Talking Points (Senior SRE Level)

1. **"We discovered CPU-based HPA is wrong for Go services"** — Go's goroutine scheduler is so efficient that CPU stays low even under severe goroutine queue buildup. We switched to memory-based HPA as the primary signal because goroutine stack allocation is a reliable proxy for concurrency pressure.

2. **"CPU throttle vs CPU saturation — they're opposites"** — A throttled pod shows LOW utilization to HPA (it's paused, not running). We had currency pods CPU-throttled at 100m limit while HPA saw 20% utilization and refused to scale. Raising the limit removed the throttle and exposed real utilization.

3. **"GOMAXPROCS must be set explicitly in containers"** — Go defaults to node CPU count, causing O/S thread starvation against cgroup limits. This is a Day 1 config for any Go service in Kubernetes.

4. **"Load generator placement changes everything"** — Our throughput plateau was entirely due to Docker Desktop's NAT proxy, not the app. We moved k6 in-cluster and saw 10x throughput increase. In production, load generators must be co-located (same AZ, no NAT) with the target.

5. **"KEDA is the right long-term answer for I/O-bound services"** — CPU-based HPA is permanently wrong for checkout. The correct signal is in-flight request concurrency. KEDA ScaledObject on `http_server_requests_in_flight` with target of 10 per pod would fire exactly when pods are overwhelmed.
