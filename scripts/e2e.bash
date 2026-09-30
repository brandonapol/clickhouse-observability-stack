#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_TIMEOUT=${SYNC_TIMEOUT:-1200}
DATA_TIMEOUT=${DATA_TIMEOUT:-300}

step() { echo "==> $*"; }

expected="$(helm template app-of-apps cluster-configs/app-of-apps -f cluster-configs/overrides/values-local.yaml |
  yq ea '[select(.kind == "Application")] | length')"
expected=$((expected + 1))

step "Waiting for $expected Applications to be Synced and Healthy"
deadline=$((SECONDS + SYNC_TIMEOUT))
while :; do
  status="$(kubectl -n argocd get applications -o json)"
  ready="$(jq '[.items[] | select(.status.sync.status == "Synced" and .status.health.status == "Healthy")] | length' <<<"$status")"
  total="$(jq '.items | length' <<<"$status")"
  if ((total == expected && ready == expected)); then
    break
  fi
  if ((SECONDS > deadline)); then
    kubectl -n argocd get applications
    jq -r '.items[] | "\(.metadata.name): \(.status.sync.status)/\(.status.health.status) \(.status.conditions // [] | map(.message) | join("; "))"' <<<"$status"
    kubectl get pods -A
    echo "Applications did not become Synced and Healthy within ${SYNC_TIMEOUT}s"
    exit 1
  fi
  echo "  $ready/$expected ready ($total present)"
  sleep 15
done

kubectl -n observability port-forward svc/cerberus 18081:8080 >/dev/null 2>&1 &
kubectl -n observability port-forward svc/grafana 13000:80 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 3

cerberus=http://localhost:18081
grafana=http://localhost:13000

poll() {
  local description=$1 check=$2
  shift 2
  local deadline=$((SECONDS + DATA_TIMEOUT)) body
  step "$description"
  while :; do
    body="$(curl -fsS -G "$@" 2>/dev/null || true)"
    if [[ -n "$body" ]] && jq -e "$check" <<<"$body" >/dev/null 2>&1; then
      echo "  ok"
      return 0
    fi
    if ((SECONDS > deadline)); then
      echo "  last response: ${body:0:500}"
      echo "  not satisfied within ${DATA_TIMEOUT}s: $check"
      exit 1
    fi
    sleep 10
  done
}

now="$(date +%s)"
start=$((now - 900))
end=$((now + 900))

poll "PromQL: span metrics exist for checkout and payments" \
  '[.data.result[].metric.service_name] | contains(["checkout", "payments"])' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum by (service_name) (rate(traces_span_metrics_calls[2m]))'

poll "PromQL: payments error ratio is about 25%" \
  '.data.result[0].value[1] | tonumber | . > 0.1 and . < 0.4' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(rate(traces_span_metrics_calls{service_name="payments",status_code="STATUS_CODE_ERROR"}[2m])) / sum(rate(traces_span_metrics_calls{service_name="payments"}[2m]))'

poll "PromQL: checkout has no errors" \
  '.data.result | length == 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=sum(rate(traces_span_metrics_calls{service_name="checkout",status_code="STATUS_CODE_ERROR"}[2m])) > 0'

poll "PromQL: service graph metrics exist" \
  '.data.result | length > 0' \
  "$cerberus/api/v1/query" --data-urlencode 'query=traces_service_graph_request_total'

poll "LogQL: checkout logs arrive" \
  '[.data.result[].values[]] | length > 0' \
  "$cerberus/loki/api/v1/query_range" --data-urlencode 'query={service_name="checkout"}' \
  --data-urlencode "start=${start}000000000" --data-urlencode "end=${end}000000000" --data-urlencode 'limit=10'

poll "TraceQL: failing payments traces are searchable" \
  '.traces | length > 0' \
  "$cerberus/api/search" --data-urlencode 'q={resource.service.name="payments" && status=error}' \
  --data-urlencode "start=$start" --data-urlencode "end=$end" --data-urlencode 'limit=5'

for uid in cerberus-prometheus cerberus-loki cerberus-tempo; do
  poll "Grafana: datasource $uid is healthy" \
    '.status == "OK"' \
    -u admin:admin "$grafana/api/datasources/uid/$uid/health"
done

poll "Grafana: the span-metrics dashboard is provisioned" \
  '.dashboard.uid == "span-metrics-red"' \
  -u admin:admin "$grafana/api/dashboards/uid/span-metrics-red"

echo "e2e: ok"
