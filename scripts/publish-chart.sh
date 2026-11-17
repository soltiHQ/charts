#!/usr/bin/env bash
# Publishes the chart version a release tag names. TAG is <chart>-<version>, as
# podium-0.0.2: charts/<chart>/Chart.yaml must have that name and that version,
# and the registry must not hold that version yet, as a version is published
# once and never pushed again. It packages the chart and pushes it to
# REGISTRY/<chart>. Needs helm, logged in to the registry (helm registry login).
# PLAIN_HTTP=1 talks plain HTTP, for a local test registry.
set -euo pipefail

usage='usage: publish-chart.sh TAG oci://REGISTRY/PATH'
tag=${1:?$usage}
registry=${2:?$usage}
cd "$(dirname "$0")/.."

# The version is SemVer, a pre-release such as -rc.1 included; a chart's name
# has no dot, so the version starts after the last "-" followed by a number.
if [[ ! $tag =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?)-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$ ]]; then
  echo "tag $tag is not <chart>-<version>, as podium-0.0.2" >&2
  exit 1
fi
chart=${BASH_REMATCH[1]}
version=${BASH_REMATCH[3]}
dir=charts/$chart
if [ ! -f "$dir/Chart.yaml" ]; then
  echo "tag $tag: there is no chart $chart, no $dir/Chart.yaml" >&2
  exit 1
fi
name=$(awk '/^name:/ {print $2; exit}' "$dir/Chart.yaml")
have=$(awk '/^version:/ {print $2; exit}' "$dir/Chart.yaml")
if [ "$name" != "$chart" ] || [ "$have" != "$version" ]; then
  echo "tag $tag: $dir/Chart.yaml is $name $have, not $chart $version" >&2
  exit 1
fi

flags=()
if [ "${PLAIN_HTTP:-}" = 1 ]; then
  flags=(--plain-http)
fi
# A registry overwrites a tag it holds: push only once it answered that the
# version is not there, and stop on any other answer.
if out=$(helm show chart "$registry/$chart" --version "$version" ${flags[@]+"${flags[@]}"} 2>&1); then
  echo "$chart $version is in $registry already: a version is published once, tag a new one" >&2
  exit 1
elif ! grep -qi 'not found' <<<"$out"; then
  echo "could not tell whether $registry holds $chart $version:" >&2
  echo "$out" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
helm package "$dir" --destination "$work" >/dev/null
helm push "$work/$chart-$version.tgz" "$registry" ${flags[@]+"${flags[@]}"}
echo "$chart $version: pushed to $registry/$chart"
