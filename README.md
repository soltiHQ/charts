# charts

Helm charts for solti, published as OCI artifacts on GHCR:
`oci://ghcr.io/soltihq/charts/<chart>`.

| Chart | What it deploys |
| -- | -- |
| [podium](charts/podium/README.md) | podium, the solti control plane: one node with its state in memory, or replicas that share a Postgres database. |

```sh
helm install podium oci://ghcr.io/soltihq/charts/podium --version <version> \
  -n podium --create-namespace --set secrets.existingSecret=podium-secrets
```

Each chart's README lists what it needs before the install. Helm 3.8 or later
installs from an OCI registry; Argo CD and Flux read one as well.

## Publishing

A tag publishes a chart: `<chart>-<version>`, as `podium-0.1.0` or
`podium-0.1.0-rc.1`, on a commit of `main`. The tag is the version: the chart is
packaged with it (`helm package --version`), and the `version` in `Chart.yaml`,
`0.0.0`, serves local renders only. A merge to `main` publishes nothing. The
release workflow, `.github/workflows/release.yml`, checks that the tag's commit
is on `main`, runs the checks of the PR workflow again, and pushes the chart to
`oci://ghcr.io/soltihq/charts/<chart>` (`scripts/publish-chart.sh`). A version
GHCR holds already stops it: a version is published once, and never pushed
again.

```sh
git switch main && git pull --ff-only
git tag podium-0.1.0
git push origin podium-0.1.0
```

A tag whose release failed before the push, its version not in GHCR, moves to
the fixed commit: `git push origin :refs/tags/<tag>`, then tag and push again.

The PR workflow lints every chart with `helm lint --strict`, renders it with
each of its `ci/*-values.yaml` files, and validates the result against the
Kubernetes schemas with kubeconform. The same checks run locally:

```sh
./scripts/check-charts.sh   # needs helm and docker
```

The first source in a chart's `Chart.yaml` becomes its OCI package's
`org.opencontainers.image.source`, which links the package on GHCR to a
repository: keep `https://github.com/soltiHQ/charts` first, so that this
repository's workflow may push the next versions.

Before the first publish, an owner of the soltiHQ organization must allow this
repository's workflows to publish packages with `GITHUB_TOKEN`. A package GHCR
creates may start private: make `charts/podium` public in the organization's
package settings for installs without credentials.
