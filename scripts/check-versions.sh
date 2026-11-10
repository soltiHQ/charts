#!/usr/bin/env bash
# Fails when a chart under charts/ changed against BASE (a git ref, origin/main
# in a pull request) while the version in its Chart.yaml stayed the same: a
# published chart version is never pushed again, so a change needs a new one.
set -euo pipefail

base=${1:?usage: check-versions.sh BASE_REF}
cd "$(dirname "$0")/.."

status=0
for chart in charts/*/; do
  chart=${chart%/}
  if git diff --quiet "$base"...HEAD -- "$chart"; then
    continue
  fi
  new=$(awk '/^version:/ {print $2; exit}' "$chart/Chart.yaml")
  old=$(git show "$base:$chart/Chart.yaml" 2>/dev/null | awk '/^version:/ {print $2; exit}' || true)
  if [ -z "$old" ]; then
    echo "$chart: new chart, version $new"
  elif [ "$old" = "$new" ]; then
    echo "::error file=$chart/Chart.yaml::$chart changed against $base but its version is still $new: raise it"
    status=1
  else
    echo "$chart: version $old -> $new"
  fi
done
exit "$status"
