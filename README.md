# charts

Helm charts for solti, published as OCI artifacts on GHCR:
`oci://ghcr.io/soltihq/charts/<chart>`.

| Chart | What it deploys |
| -- | -- |
| [podium](charts/podium/README.md) | podium, the solti control plane: one node with its state in memory, or replicas that share a Postgres database. |

```sh
helm install podium oci://ghcr.io/soltihq/charts/podium --version 0.0.2 \
  -n podium --create-namespace --set secrets.existingSecret=podium-secrets
```

Each chart's README lists what it needs before the install. Helm 3.8 or later
installs from an OCI registry; Argo CD and Flux read one as well.

## Publishing

A tag publishes a chart version: `<chart>-<version>`, as `podium-0.0.2`, on a
commit of `main`. A merge to `main` publishes nothing. The release workflow,
`.github/workflows/release.yml`, checks that the tag's commit is on `main` and
that `charts/<chart>/Chart.yaml` has that name and that version, runs the checks
of the PR workflow again, and pushes the chart to
`oci://ghcr.io/soltihq/charts/<chart>` (`scripts/publish-chart.sh`). A version
GHCR holds already stops it: a version is published once, and never pushed
again. A pre-release takes a SemVer pre-release version, as `podium-0.1.0-rc.1`.

```sh
git switch main && git pull --ff-only
git tag podium-0.0.2
git push origin podium-0.0.2
```

A change to a chart needs a new `version` in its `Chart.yaml`, so that each
version has one content, and the PR workflow fails a pull request that changes a
chart without one.

The PR workflow lints every chart with `helm lint --strict`, renders it with
each of its `ci/*-values.yaml` files, and validates the result against the
Kubernetes schemas with kubeconform. The same checks run locally:

```sh
./scripts/check-charts.sh                 # needs helm and docker
./scripts/check-versions.sh origin/main   # needs the main branch fetched
```

The first source in a chart's `Chart.yaml` becomes its OCI package's
`org.opencontainers.image.source`, which links the package on GHCR to a
repository: keep `https://github.com/soltiHQ/charts` first, so that this
repository's workflow may push the next versions.

Before the first publish, an owner of the soltiHQ organization must allow this
repository's workflows to publish packages with `GITHUB_TOKEN`. A package GHCR
creates may start private: make `charts/podium` public in the organization's
package settings for installs without credentials.
