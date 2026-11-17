#!/usr/bin/env bash
# Publishes the chart version a release tag names. TAG is <chart>-<version>, as
# podium-0.1.0 or podium-0.1.0-rc.1: the tag is the version, which the chart is
# packaged with (helm package --version), whatever its Chart.yaml says, and the
# registry must not hold that version yet, as a version is published once and
# never pushed again. charts/<chart>/Chart.yaml must name the chart <chart>. It
# pushes the chart to REGISTRY/<chart>. Needs helm, logged in to the registry
# (helm registry login). PLAIN_HTTP=1 talks plain HTTP, for a local test
# registry.
set -euo pipefail

usage='usage: publish-chart.sh TAG oci://REGISTRY/PATH'
tag=${1:?$usage}
registry=${2:?$usage}
cd "$(dirname "$0")/.."

# The version is SemVer, a pre-release such as -rc.1 included; a chart's name
# has no dot, so the version starts after the last "-" followed by a number.
if [[ ! $tag =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?)-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$ ]]; then
  echo "tag $tag is not <chart>-<version>, as podium-0.1.0" >&2
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
if [ "$name" != "$chart" ]; then
  echo "tag $tag: $dir/Chart.yaml names the chart $name, not $chart" >&2
  exit 1
fi

flags=()
if [ "${PLAIN_HTTP:-}" = 1 ]; then
  flags=(--plain-http)
fi
# A registry overwrites a tag it holds: push only once it answered that the
# version is not there, and stop on any other answer, as a timeout. A refusal to
# read counts as not there: GHCR refuses a package that does not exist yet, as
# after its deletion, and a token refused the read is refused the push as well,
# so nothing is overwritten.
if out=$(helm show chart "$registry/$chart" --version "$version" ${flags[@]+"${flags[@]}"} 2>&1); then
  echo "$chart $version is in $registry already: a version is published once, tag a new one" >&2
  exit 1
elif ! grep -qiE 'not found|name unknown|manifest unknown|denied|unauthorized|forbidden|\b40[134]\b' <<<"$out"; then
  echo "could not tell whether $registry holds $chart $version:" >&2
  echo "$out" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
helm package "$dir" --version "$version" --destination "$work" >/dev/null
helm push "$work/$chart-$version.tgz" "$registry" ${flags[@]+"${flags[@]}"}
echo "$chart $version: pushed to $registry/$chart"
