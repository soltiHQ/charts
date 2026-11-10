# charts

Helm charts for solti, published as OCI artifacts on GHCR:
`oci://ghcr.io/soltihq/charts/<chart>`.

| Chart | What it deploys |
| -- | -- |
| [podium](charts/podium/README.md) | podium, the solti control plane, as one standalone node with its state on a persistent volume. |

```sh
helm install podium oci://ghcr.io/soltihq/charts/podium --version 0.0.1 \
  -n podium --create-namespace --set secrets.existingSecret=podium-secrets
```

Each chart's README lists what it needs before the install. Helm 3.8 or later
installs from an OCI registry; Argo CD and Flux read one as well.

## Publishing

A merge to `main` that touches `charts/` runs the release workflow,
`.github/workflows/release.yml`: it pushes each chart version that GHCR does not
hold yet, and leaves a version already there alone. So a change to a chart needs
a new `version` in its `Chart.yaml`, and the PR workflow fails a pull request
that changes a chart without one.

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
