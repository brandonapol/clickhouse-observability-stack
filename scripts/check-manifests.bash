#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION must be set}
K8S_SCHEMAS_REF=8df8a883b68a24a104b4a9e43c1288090ae60b3b
CRD_CATALOG_REF=d373c2da9702bc9509a004db83e57263fe3bdfc1
K8S_SCHEMAS="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMAS_REF/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
CRD_CATALOG="https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_CATALOG_REF/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

echo "==> Validating tests/golden and the bootstrap Applications with kubeconform"
kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" \
  -schema-location "$K8S_SCHEMAS" \
  -schema-location "$CRD_CATALOG" \
  tests/golden cluster-configs/app-of-apps/app-of-apps-*.yaml

echo "==> Checking every container has a memory limit and a pinned image"
errors=0
check_container() {
  local file=$1 object=$2 container=$3 image=$4 limit=$5
  if [[ "$limit" == null ]]; then
    echo "  $file: $object container $container has no memory limit"
    errors=$((errors + 1))
  fi
  if [[ "$image" != *:* || "$image" == *:latest ]]; then
    echo "  $file: $object container $container image $image is not pinned"
    errors=$((errors + 1))
  fi
}
for file in tests/golden/*/*.yaml; do
  while IFS=$'\t' read -r object container image limit; do
    [[ -n "$object" ]] && check_container "$file" "$object" "$container" "$image" "$limit"
  done < <(yq ea -r "[
    select(.kind == \"Deployment\" or .kind == \"ClickHouseInstallation\") |
    (.kind + \"/\" + .metadata.name) as \$object |
    (.spec.template.spec.containers // [.spec.templates.podTemplates[].spec.containers[]])[] |
    [\$object, .name, .image, (.resources.limits.memory // \"null\")] | @tsv
    ] | .[]" "$file")
done

if ((errors > 0)); then
  echo "check-manifests: $errors problem(s) found"
  exit 1
fi
echo "check-manifests: ok"
