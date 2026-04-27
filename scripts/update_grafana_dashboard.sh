#!/usr/bin/env bash
# Run from: ~/sre/k8s/scripts/

GRAFANA="http://localhost:31029"
AUTH="admin:admin"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
DIR="$SCRIPTS_DIR/../observability/grafana/dashboards"

mkdir -p "$DIR"

curl -s "$GRAFANA/api/search?type=dash-db" -u "$AUTH" \
  | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 \
  | while read -r uid; do
      curl -s "$GRAFANA/api/dashboards/uid/$uid" -u "$AUTH" > "$DIR/$uid.json"
      echo "saved: $uid"
    done

cd "$REPO_ROOT"
git add k8s/observability/grafana/dashboards/
git commit -m "export: grafana dashboards $(date +%Y-%m-%d)" || echo "nothing to commit"
git push origin main