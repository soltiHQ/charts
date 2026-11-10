#!/usr/bin/env bash
# Packages every chart under charts/ and pushes each chart version that the
# registry does not hold yet: a version already there is left alone, never
# pushed again. Needs helm, logged in to the registry (helm registry login).
# PLAIN_HTTP=1 talks plain HTTP, for a local test registry.
set -euo pipefail

registry=${1:?usage: publish-charts.sh oci://REGISTRY/PATH}
cd "$(dirname "$0")/.."

flags=()
if [ "${PLAIN_HTTP:-}" = 1 ]; then
  flags=(--plain-http)
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

for chart in charts/*/; do
  chart=${chart%/}
  name=$(awk '/^name:/ {print $2; exit}' "$chart/Chart.yaml")
  version=$(awk '/^version:/ {print $2; exit}' "$chart/Chart.yaml")
  if helm show chart "$registry/$name" --version "$version" "${flags[@]}" >/dev/null 2>&1; then
    echo "$name $version: already in $registry, left alone"
    continue
  fi
  helm package "$chart" --destination "$out" >/dev/null
  helm push "$out/$name-$version.tgz" "$registry" "${flags[@]}"
  echo "$name $version: pushed to $registry/$name"
done
