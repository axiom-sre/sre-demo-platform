#!/usr/bin/env bash
# Run from: ~/sre/k8s/scripts/
# Usage: ./update_grafana_dashboard.sh

set -euo pipefail

GRAFANA="http://grafana.local"
AUTH="admin:admin"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
DIR="$SCRIPTS_DIR/../observability/grafana/dashboards"

mkdir -p "$DIR"

echo "→ Fetching dashboard list..."
curl -s "$GRAFANA/api/search?type=dash-db" -u "$AUTH" \
  | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(d['uid'], d['title'])
" \
  | while read -r uid title; do
      # Slugify title for filename
      slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
      outfile="$DIR/${slug}.json"

      # Export dashboard JSON, strip volatile fields that cause noisy diffs
      curl -s "$GRAFANA/api/dashboards/uid/$uid" -u "$AUTH" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
db = data['dashboard']
# Strip fields Grafana mutates on every save
for key in ('id', 'version', 'iteration'):
    db.pop(key, None)
print(json.dumps({'dashboard': db, 'meta': {'slug': data['meta']['slug']}}, indent=2))
" > "$outfile"

      echo "  saved: $outfile"
    done

cd "$REPO_ROOT"
git add k8s/observability/grafana/dashboards/
git diff --cached --stat

git commit -m "obs(grafana): export dashboards $(date -u +%Y-%m-%dT%H:%M)" \
  || echo "nothing to commit"
git push origin main