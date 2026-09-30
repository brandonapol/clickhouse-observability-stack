#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}
out=${1:?usage: render.bash <output-dir>}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for overrides in cluster-configs/overrides/values-*.yaml; do
  env="$(basename "$overrides" .yaml)"
  env="${env#values-}"
  mkdir -p "$out/$env"

  helm template app-of-apps cluster-configs/app-of-apps --namespace argocd \
    --kube-version "$KUBE_VERSION" -f "$overrides" >"$out/$env/app-of-apps.yaml"

  while IFS= read -r app; do
    yq "select(.metadata.name == \"$app\") | .spec.source.helm.valuesObject" "$out/$env/app-of-apps.yaml" >"$work/values.yaml"
    path="$(yq "select(.metadata.name == \"$app\") | .spec.source.path" "$out/$env/app-of-apps.yaml")"
    release="$(yq "select(.metadata.name == \"$app\") | .spec.source.helm.releaseName" "$out/$env/app-of-apps.yaml")"
    namespace="$(yq "select(.metadata.name == \"$app\") | .spec.destination.namespace" "$out/$env/app-of-apps.yaml")"

    helm template "$release" "$path" --namespace "$namespace" --kube-version "$KUBE_VERSION" \
      -f "$work/values.yaml" >"$out/$env/$release.yaml"
  done < <(yq ea '[select(.kind == "Application") | .metadata.name] | .[]' "$out/$env/app-of-apps.yaml")
done
