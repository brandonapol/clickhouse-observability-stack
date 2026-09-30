#!/usr/bin/env bash
# Create a local kind cluster, install Argo CD, and hand everything else to
# the app-of-apps (cluster-configs/app-of-apps/app-of-apps-local.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."

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

echo "==> Applying the local app-of-apps"
kubectl apply -f cluster-configs/app-of-apps/app-of-apps-local.yaml

cat <<'MSG'

Argo CD is now syncing the stack. Watch progress with:
  kubectl -n argocd get applications -w
All apps should reach Synced / Healthy within a few minutes. Then run:
  scripts/port-forward.sh
MSG
