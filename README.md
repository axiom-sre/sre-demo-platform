# 🔱 SRE Demo Platform — Holy Grail Edition

> A production-grade SRE learning platform running on Kubernetes (Docker Desktop), featuring the Google Online Boutique microservices app instrumented with a full LGTM observability stack, HPA, chaos readiness, and load testing harness.

[![CI — Manifest Validation](https://github.com/axiom-sre/sre-demo-platform/actions/workflows/ci.yaml/badge.svg)](https://github.com/axiom-sre/sre-demo-platform/actions/workflows/ci.yaml)
[![Stack](https://img.shields.io/badge/stack-LGTM-orange)](https://grafana.com/oss/)
[![k8s](https://img.shields.io/badge/kubernetes-docker--desktop-blue)](https://www.docker.com/products/docker-desktop/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────┐
│  namespace: boutique                                    │
│  Google Online Boutique (11 microservices)              │
│  frontend · cart · checkout · product · recommend ...   │
│  HPA on 6 services — scales to 1000+ VU                │
└────────────────────┬────────────────────────────────────┘
                     │ OTLP traces · pod logs · /metrics
┌────────────────────▼────────────────────────────────────┐
│  namespace: observability  (LGTM stack)                 │
│                                                         │
│  Grafana Alloy (DaemonSet)                              │
│    ├─ Traces  → Tempo   (2.4.1)   ← trace backend      │
│    ├─ Metrics → Prometheus (2.51) ← metrics backend    │
│    └─ Logs    → Loki (3.0.0)      ← log backend        │
│                                                         │
│  Grafana (10.x) — 3 pre-loaded dashboards              │
│    ├─ Golden Signals                                    │
│    ├─ Pod & Platform Stats                              │
│    └─ SLI / SLO / Error Budget                         │
└─────────────────────────────────────────────────────────┘
```

## 🗂️ Repo Layout

```
k8s/
├── boutique/
│   ├── boutique.yaml          # All 11 boutique services + Redis
│   └── hpa.yaml               # HPA for 6 services (CPU-budget tuned)
├── namespaces/
│   ├── namespaces.yaml        # observability + boutique namespaces + ResourceQuotas
│   └── priority-classes.yaml  # observability-high + system-node-critical
├── observability/
│   ├── alloy/alloy.yaml       # DaemonSet: OTLP collector + log shipper (River syntax)
│   ├── grafana/grafana.yaml   # Grafana + 3 dashboards (PVC-backed)
│   ├── infrastructure/        # metrics-server, node-exporter, kube-state-metrics
│   ├── loki/loki.yaml         # Loki 3.0 (filesystem backend)
│   ├── prometheus/prometheus.yaml  # Prometheus 2.51 (TSDB + remote_write receiver)
│   └── tempo/tempo.yaml       # Tempo 2.4.1 (WAL + metrics_generator)
└── scripts/
    ├── bootstrap.sh           # First-time setup (run once)
    ├── start.sh               # Full stack startup (after every reboot)
    ├── manage.sh              # stop / nuke / status / debug / logs / budget
    ├── verify-stability.sh    # Pipeline health verification
    ├── find-url.sh            # Finds the correct k6 BASE_URL
    ├── load-test_10vusers.js  # Smoke test
    ├── load-test_100vusers.js # Moderate load
    └── load-test_1000vusers.js # Full chaos-ready load test
```

## ⚡ Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | 4.28+ | [docker.com](https://www.docker.com/products/docker-desktop/) |
| kubectl | 1.29+ | `brew install kubectl` |
| k6 | 0.50+ | `brew install k6` |

**Docker Desktop resources (required):**
- Memory: **24 GB** (minimum 20 GB)
- CPU: **8 cores**
- Enable Kubernetes in Docker Desktop → Settings → Kubernetes

### First-time setup (once per machine)

```bash
git clone git@github.com:axiom-sre/sre-demo-platform.git
cd sre-demo-platform/k8s
bash scripts/bootstrap.sh
```

Bootstrap takes ~5-10 min on first run (image pulls ~2 GB).

### After every reboot

```bash
cd k8s
bash scripts/start.sh
```

### Verify everything is healthy

```bash
bash scripts/verify-stability.sh --short
bash scripts/manage.sh status
bash scripts/manage.sh budget
```

---

## 🌐 Endpoints

| Service | URL | Notes |
|---------|-----|-------|
| Boutique | http://localhost:8080 | LoadBalancer → NodePort 30080 |
| Grafana | http://localhost:3000 | `admin` / `admin` |
| Prometheus | http://localhost:9090 | |
| Alloy UI | http://localhost:12345 | Pipeline graph |
| Tempo | http://localhost:3200 | |
| Loki | http://localhost:3100 | |

---

## 🔥 Load Testing

```bash
# Find the correct BASE_URL for your Docker Desktop config
export BASE_URL=$(bash scripts/find-url.sh --export)

# Smoke test (10 VU, 2 min)
k6 run --env BASE_URL=$BASE_URL scripts/load-test_10vusers.js

# Moderate load (100 VU)
k6 run --env BASE_URL=$BASE_URL scripts/load-test_100vusers.js

# Full load — triggers HPA scale-out (1000 VU)
k6 run --env BASE_URL=$BASE_URL scripts/load-test_1000vusers.js

# Watch HPA react in real time (separate terminal)
bash scripts/manage.sh hpa-watch
```

---

## 🛠️ Operations

```bash
bash scripts/manage.sh status       # pod + HPA + PVC status
bash scripts/manage.sh debug        # full diagnostic dump
bash scripts/manage.sh budget       # node CPU/memory budget
bash scripts/manage.sh logs frontend boutique   # tail service logs
bash scripts/manage.sh cart-debug   # deep-dive cartservice diagnostics
bash scripts/manage.sh restart frontend boutique
bash scripts/manage.sh top          # kubectl top for both namespaces
bash scripts/manage.sh stop         # graceful teardown (PVCs preserved)
bash scripts/manage.sh nuke         # full reset, deletes all data
```

---

## 📊 Grafana Dashboards

Three pre-loaded dashboards (survive pod restarts via PVC):

| Dashboard | What it shows |
|-----------|--------------|
| **Boutique — Golden Signals** | Latency, traffic, errors, saturation per service |
| **Boutique — Pod & Platform Stats** | HPA replica counts, CPU/memory by pod, node pressure |
| **Boutique — SLI / SLO / Error Budget** | 99.9% availability SLO, error budget burn rate |

---

## 🏗️ Design Decisions

### Why Alloy as a DaemonSet?
Log collection via `hostPath:/var/log/pods` requires one agent per node. A DaemonSet ensures Alloy is on every node automatically. `system-node-critical` PriorityClass means it survives node pressure events.

### Why PriorityClasses?
At 1000 VU, boutique HPA scale-out creates node CPU/memory pressure. Without priority, the scheduler evicts observability pods first (largest memory consumers). `observability-high` ensures Prometheus, Tempo, and Loki survive boutique scaling storms.

### Why the cart HPA maxReplicas was reduced from 8 → 5?
8 × 500m = 4000m requests for cartservice alone. At 1000 VU this fires simultaneously with frontend scaling (10 × 500m = 5000m), exhausting node CPU budget and causing cascading Pending pods. See `hpa.yaml` for full budget math.

### Why 60s terminationGracePeriodSeconds on Tempo?
Tempo's ingester WAL flush + block compaction takes 15-30s under load. SIGTERM during this window loses the current WAL block. 30s was too tight at 1000 VU sustained for 10+ min.

---

## 🗺️ Roadmap

- [ ] Chaos Engineering (Chaos Mesh / LitmusChaos)
- [ ] Alerting rules (Prometheus alertmanager)
- [ ] PagerDuty / Slack alert routing
- [ ] SLO burn rate alerts (Sloth)
- [ ] Distributed load testing (k6 operator)
- [ ] GitOps (FluxCD / ArgoCD)
- [ ] Multi-cluster simulation (kind)
- [ ] Runbook automation

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## 📄 License

MIT — see [LICENSE](LICENSE).
