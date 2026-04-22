bash scripts/manage.sh grafana-export

sleep 1

git add observability/grafana/dashboards/

sleep 1

git commit -m "export: grafana dashboards snapshot $(date +%Y-%m-%d)

- Golden Signals Deep Dive

- Infrastructure & Node

- Platform & HPA

- SLO & Error Budget

- SRE Command Center"

sleep 1

git push origin main