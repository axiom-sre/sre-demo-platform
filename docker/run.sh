#!/bin/bash
# Usage:
#   bash run.sh up      — start everything
#   bash run.sh down    — stop everything (keeps volumes)
#   bash run.sh nuke    — stop + delete all volumes (full reset)
#   bash run.sh status  — show running containers + ports
#   bash run.sh logs    — tail all logs
#   bash run.sh verify  — run golden signal queries against Prometheus

set -euo pipefail
CMD=${1:-up}

case "$CMD" in
  up)
    echo "▶ Pulling images..."
    docker compose pull --quiet
    echo "▶ Starting stack..."
    docker compose up -d
    echo ""
    echo "══════════════════════════════════════════"
    echo " ✅  Stack is up — wait ~30s for services"
    echo "══════════════════════════════════════════"
    echo ""
    echo "  Boutique:    http://localhost:8080"
    echo "  Grafana:     http://localhost:3000   (admin / admin)"
    echo "  Prometheus:  http://localhost:9090"
    echo "  Alloy UI:    http://localhost:12345"
    echo "  Tempo:       http://localhost:3200"
    echo "  Loki:        http://localhost:3100"
    echo ""
    echo "Golden signals dashboard → Grafana > Boutique — Golden Signals"
    ;;

  down)
    echo "▶ Stopping stack (volumes preserved)..."
    docker compose down
    ;;

  nuke)
    echo "▶ Nuking everything including volumes..."
    docker compose down -v --remove-orphans
    echo "✅  Clean slate."
    ;;

  status)
    docker compose ps
    ;;

  logs)
    docker compose logs -f --tail=50
    ;;

  verify)
    echo "▶ Checking golden signal metrics in Prometheus..."
    echo ""
    BASE="http://localhost:9090/api/v1/query"

    check() {
      local label=$1
      local query=$2
      local result
      result=$(curl -sg "$BASE" --data-urlencode "query=$query" | \
               python3 -c "import sys,json; d=json.load(sys.stdin); print('✅  HAS DATA' if d['data']['result'] else '❌  NO DATA')" 2>/dev/null || echo "⚠️  Prometheus unreachable")
      printf "  %-45s %s\n" "$label" "$result"
    }

    check "http_server_request_duration_seconds_bucket" \
      'count(http_server_request_duration_seconds_bucket)'
    check "p95 latency" \
      'histogram_quantile(0.95, sum by(le,service_name)(rate(http_server_request_duration_seconds_bucket[5m])))'
    check "p99 latency" \
      'histogram_quantile(0.99, sum by(le,service_name)(rate(http_server_request_duration_seconds_bucket[5m])))'
    check "request rate" \
      'sum by(service_name)(rate(http_server_request_duration_seconds_count[5m]))'
    echo ""
    ;;

  *)
    echo "Usage: bash run.sh [up|down|nuke|status|logs|verify]"
    exit 1
    ;;
esac
