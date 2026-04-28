# Deploy k6 as a job inside the cluster
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-load-test
  namespace: boutique
spec:
  template:
    spec:
      containers:
      - name: k6
        image: grafana/k6:latest
        command: ["k6", "run", "--vus", "1000", "--duration", "10m", 
                  "http://frontend.boutique.svc.cluster.local:80"]  # internal DNS
      restartPolicy: Never
EOF