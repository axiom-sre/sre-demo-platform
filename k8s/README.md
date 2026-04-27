# SRE Demo Platform — Online Boutique + LGTM Stack on Kubernetes

A production-grade observability demo running on Docker Desktop Kubernetes.
Full LGTM stack (Loki, Grafana, Tempo, Mimir/Prometheus) with Google's Online
Boutique microservices app, HPA auto-scaling, and SLO dashboards — designed to
handle 1000+ concurrent virtual users on an M-series MacBook.

---

## Folder Structure

```
k8s/
├── boutique/
│   ├── boutique.yaml          # 11 microservices + Redis + PodDisruptionBudgets
│   └── hpa.yaml               # HPA policies (frontend, cart, catalog, checkout, etc.)
├── charts/
│   └── sre-demo/              # Helm chart (migration path to Azure / AWS)
│       ├── Chart.yaml
│       ├── values.yaml        # single source of truth for all tunables
│       └── templates/
│           ├── _helpers.tpl
│           ├── boutique/
│           │   └── frontend.yaml   # example Helm template (pattern for all services)
│           └── cluster/
│               └── namespaces.yaml
├── cluster/
│   ├── kind-cluster.yaml      # 3-node kind cluster (optional — Docker Desktop default)
│   └── metrics-server.yaml    # standalone metrics-server manifest
├── namespaces/
│   └── namespaces.yaml        # observability + boutique namespaces
├── observability/
│   ├── alloy/
│   │   └── alloy.yaml         # OTLP collector + Kubernetes log shipper → Loki
│   ├── grafana/
│   │   └── grafana.yaml       # Datasources + 3 dashboards (Golden Signals, Platform, SLO)
│   ├── infrastructure/
│   │   └── infrastructure.yaml # node-exporter, kube-state-metrics, metrics-server
│   ├── loki/
│   │   └── loki.yaml          # Log storage (tuned for 1000 VU ingestion rate)
│   ├── prometheus/
│   │   └── prometheus.yaml    # Metrics + remote_write receiver for spanmetrics
│   └── tempo/
│       └── tempo.yaml         # Distributed tracing backend
├── scripts/
│   ├── bootstrap.sh           # First-time machine setup (run once)
│   ├── start.sh               # Full startup — run after every reboot
│   ├── manage.sh              # Operations: stop / nuke / status / debug / logs / verify
│   ├── load-test_10vusers.js  # k6 warm-up load test
│   └── load-test_1000vusers.js # k6 sustained 1000 VU load test
└── README.md
```

---

## First-Time Setup

Run once on a fresh machine:

```bash
# Prerequisites:
# 1. Install Docker Desktop: https://www.docker.com/products/docker-desktop/
# 2. Docker Desktop → Settings → Resources → 24GB RAM, 8 CPU → Apply & Restart
# 3. Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart
# 4. brew install kubectl k6 helm

bash scripts/bootstrap.sh
```

---

## Daily Use — After Every Restart

```bash
cd k8s
bash scripts/start.sh
```

That's it. The script will:
- Wait for Kubernetes to come up
- Deploy Prometheus, Loki, Tempo, Alloy, Grafana (in dependency order)
- Poll Alloy until its pipeline is warm (prevents cold-start metric gaps)
- Deploy all boutique services (Redis → leaf services → cart → checkout → frontend)
- Wait 45s for metrics-server, then apply HPA policies
- Start hardened port-forwards with auto-restart
- Verify both the metrics pipeline and the log pipeline

**Flags:**
```bash
bash scripts/start.sh --pf-only   # restart port-forwards only (stack already running)
bash scripts/start.sh --verify    # re-run pipeline check only
```

---

## Access

| URL | Service | Credentials |
|-----|---------|-------------|
| http://localhost:8080 | Online Boutique | — |
| http://localhost:3000 | Grafana | admin / admin |
| http://localhost:9090 | Prometheus | — |
| http://localhost:3100 | Loki | — |
| http://localhost:12345 | Alloy UI | — |
| http://localhost:3200 | Tempo | — |

**NodePort (no port-forward needed — use for load testing):**
- Boutique: http://localhost:30080
- Grafana: http://localhost:30300
- Prometheus: http://localhost:30900

---

## Grafana Dashboards

All three dashboards are pre-provisioned and survive pod restarts (backed by PVC):

| Dashboard | What it shows |
|-----------|---------------|
| **Boutique — Golden Signals** | RPS, error rate, p50/p90/p99 latency, service graph |
| **Boutique — Pod & Platform Stats** | Node CPU/memory, pod CPU/memory, HPA scaling history, restarts |
| **Boutique — SLI / SLO / Error Budget** | SLO compliance %, error budget remaining, burn rate |

The Tempo datasource is pre-wired with trace→log linking (click a trace span → jump to Loki logs for that pod) and trace→metrics (click a trace → see the Prometheus metrics for that service at that time).

---

## Load Testing

```bash
# Warm-up — 10 virtual users, 5 minutes
k6 run scripts/load-test_10vusers.js

# Full load — ramps to 1000 VU over 90s, holds for 8 minutes
k6 run scripts/load-test_1000vusers.js

# Watch HPA scale-out in real time (in a separate terminal)
kubectl get hpa -n boutique -w
```

**Always use NodePort for load testing** — `kubectl port-forward` is
single-goroutine per connection and cannot handle 500+ VU. NodePort (port 30080)
bypasses it entirely:

```bash
k6 run --env BASE_URL=http://localhost:30080 scripts/load-test_1000vusers.js
```

---

## Operations

```bash
# Current pod + HPA + PVC status
bash scripts/manage.sh status

# Full diagnostic dump (events, logs from all components)
bash scripts/manage.sh debug

# Tail logs for any deployment
bash scripts/manage.sh logs alloy              # defaults to observability namespace
bash scripts/manage.sh logs frontend boutique  # explicit namespace

# Verify pipelines are flowing (requires port-forwards running)
bash scripts/manage.sh verify

# Graceful stop — removes pods but preserves PVCs (Grafana data survives)
bash scripts/manage.sh stop

# Full reset — deletes everything including PVCs (prompts for confirmation)
bash scripts/manage.sh nuke
```

---

## Architecture

```
                          boutique namespace
 Browser / k6 ──────────► frontend (HPA 2-12)
                               │ gRPC
                    ┌──────────┼──────────────────────┐
                    │          │                       │
              cartservice  checkoutservice  productcatalogservice
              (HPA 2-6)    (HPA 2-6)       (HPA 2-8)
                    │          │                  + recommendationservice
                  Redis     [5 more leaf services]   + currencyservice
                                                     + adservice, etc.

 All services ──OTLP:4317──► observability namespace
                              Alloy
                              │         │
                         spanmetrics  traces ──► Tempo
                              │         │
                         Prometheus  Loki (pod logs)
                              │
                           Grafana
```

All cross-namespace traffic uses full cluster DNS:
`<service>.<namespace>.svc.cluster.local:<port>`

---

## Debugging

### Pod not starting
```bash
kubectl describe pod -n boutique -l app=cartservice
kubectl get events -n boutique --sort-by='.lastTimestamp' | tail -20
```

### Grafana panels blank / no data
```bash
# 1. Check Alloy pipeline
kubectl logs -n observability deployment/alloy --tail=50

# 2. Verify spanmetrics are flowing
bash scripts/manage.sh verify

# 3. Check Alloy UI for pipeline graph
open http://localhost:12345
```

### Logs missing in Grafana Explore (Loki empty)
```bash
# Alloy needs host volume mounts to tail pod logs
kubectl describe pod -n observability -l app=alloy | grep -A5 Volumes
kubectl logs -n observability deployment/alloy --tail=30 | grep -i loki
```

### HPA not scaling
```bash
# metrics-server must be running and registered
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n boutique
kubectl describe hpa -n boutique frontend
```

### CrashLoopBackOff
```bash
# Get logs from the previous (crashed) container
kubectl logs -n boutique deployment/cartservice --previous
kubectl describe pod -n boutique -l app=cartservice
```

### DNS between namespaces
```bash
kubectl run -it --rm debug --image=busybox --restart=Never -n boutique -- \
  nslookup alloy.observability.svc.cluster.local
```

### OOMKilled pods
```bash
kubectl top pods -n observability
kubectl top pods -n boutique
kubectl top nodes
# If memory is tight: Docker Desktop → Settings → Resources → increase to 28GB
```

---

## Helm Chart

A Helm chart is included at `charts/sre-demo/` as the migration path to
Azure AKS and AWS EKS. The `values.yaml` is the single source of truth
for all resource requests, replica counts, and HPA targets.

```bash
# Install via Helm (equivalent to kubectl apply of all files)
helm install sre-demo charts/sre-demo/ --create-namespace

# Override a value without editing files
helm upgrade sre-demo charts/sre-demo/ --set boutique.frontend.replicas=4

# Per-environment values
helm upgrade sre-demo charts/sre-demo/ -f environments/staging-values.yaml
```

The chart is growing — currently the `templates/boutique/frontend.yaml` is
the fully templated example. The remaining services follow the same pattern.

---

## Roadmap

This platform is being built toward a full SRE demo environment:

- [x] LGTM stack (Loki, Grafana, Tempo, Prometheus) on local Kubernetes
- [x] Online Boutique with 12-service microservice mesh
- [x] HPA auto-scaling with PodDisruptionBudgets
- [x] SLO dashboards with error budget burn rate
- [x] Full log pipeline (Alloy → Loki with pod metadata)
- [x] Helm chart scaffold
- [ ] Istio service mesh + mTLS
- [ ] ArgoCD GitOps deployment
- [ ] Terraform for Azure AKS + AWS EKS
- [ ] Ansible playbooks for node bootstrapping
- [ ] CI/CD pipeline (GitHub Actions)
- [ ] Alerting rules (Prometheus Alertmanager)
- [ ] Multi-cluster federation
