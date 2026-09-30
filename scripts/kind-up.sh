#!/usr/bin/env bash
# Create a local kind cluster, install Argo CD, and hand everything else to
# the app-of-apps (cluster-configs/app-of-apps/app-of-apps-local.yaml).
# Pass a git revision to deploy that commit or branch instead of main.
set -euo pipefail
cd "$(dirname "$0")/.."

REVISION=${1:-}
CLUSTER=clickhouse-obs
ARGOCD_CHART_VERSION=10.9.2

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f cluster-configs/argocd/values.yaml --wait --timeout 10m

echo "==> Applying the local app-of-apps${REVISION:+ at $REVISION}"
if [[ -n "$REVISION" ]]; then
  REVISION="$REVISION" yq '.spec.source.targetRevision = strenv(REVISION) |
    .spec.source.helm.valuesObject.targetRevision = strenv(REVISION)' \
    cluster-configs/app-of-apps/app-of-apps-local.yaml | kubectl apply -f -
else
  kubectl apply -f cluster-configs/app-of-apps/app-of-apps-local.yaml
fi

cat <<'MSG'

Argo CD is now syncing the stack. Watch progress with:
  kubectl -n argocd get applications -w
All apps should reach Synced / Healthy within a few minutes. Then run:
  scripts/port-forward.sh
MSG
