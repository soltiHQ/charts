#!/usr/bin/env bash
# Lints and renders every chart under charts/ with each of its ci/*-values.yaml
# files (or with its defaults when it has none), then validates everything it
# rendered against the Kubernetes schemas with kubeconform. Needs helm and docker.
set -euo pipefail

KUBE_VERSION=${KUBE_VERSION:-1.31.0}
# ghcr.io/yannh/kubeconform:v0.8.0
KUBECONFORM_IMAGE=${KUBECONFORM_IMAGE:-ghcr.io/yannh/kubeconform@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e}

cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

for chart in charts/*/; do
  chart=${chart%/}
  name=$(basename "$chart")
  shopt -s nullglob
  values=("$chart"/ci/*-values.yaml)
  shopt -u nullglob
  if [ ${#values[@]} -eq 0 ]; then
    values=("")
  fi
  for file in "${values[@]}"; do
    args=()
    label=defaults
    if [ -n "$file" ]; then
      args=(--values "$file")
      label=$(basename "$file" .yaml)
    fi
    echo "== $name ($label)"
    helm lint --strict "$chart" "${args[@]}"
    helm template "$name" "$chart" "${args[@]}" > "$out/$name-$label.yaml"
  done
done

# CRDs such as the Prometheus operator's ServiceMonitor have no schema there and
# are skipped, and counted as skipped in the summary.
docker run --rm -v "$out":/manifests:ro "$KUBECONFORM_IMAGE" \
  -strict -summary -ignore-missing-schemas -kubernetes-version "$KUBE_VERSION" /manifests
