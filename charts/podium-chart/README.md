# podium-chart

This chart runs [podium](https://github.com/soltiHQ/podium), the solti control
plane, as one standalone node: a StatefulSet with one replica and its state on
a ReadWriteOnce volume. A raft cluster is not covered.

| | |
| -- | -- |
| Image | `ghcr.io/soltihq/podium`, the chart's `appVersion` (`v0.0.1-rc.1`) unless `image.tag` or `image.digest` says otherwise |
| Kubernetes | 1.25 or later, with a StorageClass for ReadWriteOnce volumes |
| Helm | 3.8 or later |

## Install

Create the secrets podium needs, and keep their values somewhere safe: a
changed enrollment secret locks out every agent enrolled under the old one,
and a changed JWT secret ends every session.

```sh
kubectl create namespace podium
kubectl -n podium create secret generic podium-secrets \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=enroll-secret="$(openssl rand -hex 32)" \
  --from-literal=bootstrap-admin-password='<12 characters to 72 bytes>'

helm install podium oci://ghcr.io/soltihq/charts/podium-chart --version 0.0.1 \
  -n podium --set secrets.existingSecret=podium-secrets
```

From a checkout of this repository, `./charts/podium-chart` takes the place of the
OCI reference.

The chart can make the Secret itself from `secrets.jwtSecret`,
`secrets.enrollSecret` and `secrets.bootstrapAdminPassword` instead, but then
the values live in your Helm values and release history. It never generates
them: a value that changed at an upgrade would lock the agents out.

`bootstrap-admin-password` is the password of the first administrator, `admin`.
Set it for the first install: without it podium generates one into a file on
the volume, and the image has no shell, so neither `kubectl exec` nor
`kubectl cp` can read it. Log in, change the password, then remove the key and
restart, as podium warns about it at each start while users exist:

```sh
kubectl -n podium patch secret podium-secrets --type=json \
  -p='[{"op":"remove","path":"/data/bootstrap-admin-password"}]'
kubectl -n podium rollout restart statefulset/podium
```

## Agents

Agents sync with podium over the `<release>-agents` Service: HTTP discovery on
8082 and gRPC on 50051. It is a ClusterIP Service by default; agents outside the
cluster need `agents.service.type` `LoadBalancer` or `NodePort`, and
`agents.service.externalTrafficPolicy: Local` keeps their source IPs. podium
also calls each agent at the endpoint the agent registers, so the agents'
endpoints must be reachable from the pod.

With the enrollment secret set, an agent enrolls only with the token podium
derives for its ID. Derive one with the binary in the pod, which reads the
secret from its environment:

```sh
kubectl -n podium exec podium-0 -- /podium agent-token agent-1
```

The SDK sends the token only over TLS unless the agent allows insecure token
transport, so give podium a certificate: `tls.server.secretName` names a
`kubernetes.io/tls` Secret, cert-manager's for example, and puts TLS on 8080,
8082 and 50051. `tls.server.clientCA` makes the agents' listeners require a
client certificate of the agents' CA as well. podium reads the files at start
only: restart the pod after a renewal. The chart refuses to render without an
enrollment secret unless `secrets.allowOpenEnrollment` is `true`, as without
one any host that reaches the agents' listeners can enroll a new agent ID.

## Web UI

The `<release>` Service serves the UI and the REST API on 8080; `ingress`
exposes it. Behind an ingress that terminates TLS, list the ingress pods' CIDR
in `config.trusted_proxies`, so that podium sees the client's IP and that it
used HTTPS, or set `config.auth.cookie_secure: always`. The ingress keeps its
read timeout above 15 seconds, as a quiet event or log stream sends a keepalive
only every 15 seconds. With `tls.server` set, 8080 serves HTTPS too, and the
ingress must use HTTPS to the backend.

## Health and metrics

podium's ops listener, 8081, serves `/livez`, `/readyz`, `/leaderz`,
`/version` and `/metrics` over plain HTTP without authentication. The probes
use it on the pod: startup and liveness on `/livez`, readiness on `/readyz`,
which turns to 503 at SIGTERM. `server.shutdown_delay: 5s` gives Kubernetes the
time to take the pod out of its Services before podium stops accepting, and
`terminationGracePeriodSeconds: 60` covers the delay, the 15-second
`server.shutdown_timeout` and the 30 seconds podium takes to close its store.
Raise the grace period with either setting.

The `<release>-ops` Service is for scraping and must stay internal.
`metrics.serviceMonitor.enabled` adds a ServiceMonitor for the Prometheus
operator. `helm test <release>` checks `/readyz` through that Service.

## Data directory

The volume is mounted at `/var/lib/podium`, and podium keeps its state in
`/var/lib/podium/data`, a directory it makes itself with mode 0700. podium
refuses a data directory that its group or others may access, and the volume's
own root often is one: `fsGroup` gives it group permissions, and a hostPath
provisioner such as `local-path` makes it 0777. `fsGroup: 65532` makes the root
writable by podium, and `fsGroupChangePolicy: OnRootMismatch` keeps Kubernetes
from adding group permissions to `data` at the next start. Keep both, and keep
`SOLTI_CLUSTER_STANDALONE_DATA_DIR` as the chart sets it. A volume driver that
ignores `fsGroup` and leaves its root unwritable by uid 65532 keeps podium from
making `data`: give that root to uid 65532 with the storage's own setting.

The StatefulSet always has one replica: a second one would be a separate podium
with its own state. Its volume outlives `helm uninstall`; delete the
PersistentVolumeClaim `data-<fullname>-0` (`data-podium-0` for a release named
`podium`) yourself when you mean to drop the state.

## Configuration

`config` is podium's `podium.yaml`, mounted read-only and passed with
`--config`. podium loads it strictly: a key that is not a setting, or a key
without a value, stops it at start, with the line. The environment wins over
the file, and each setting the environment overrides is logged at INFO. The
chart sets `SOLTI_CLUSTER_STANDALONE_DATA_DIR`, and the image sets
`SOLTI_OPS_ADDR=:8081`. The chart assumes podium's default listener ports: 8080,
8081, 8082 and 50051. See
[every setting](https://github.com/soltiHQ/podium/blob/main/internal/config/README.md#every-setting).

## Back up, upgrade

A backup is a cold copy of `podium.db` with podium stopped. Scale the
StatefulSet to 0, copy the file from the volume with a pod that mounts the
claim, and scale back to 1 (a `helm upgrade` sets 1 again):

```sh
kubectl -n podium scale statefulset/podium --replicas=0
# a pod that mounts the claim data-podium-0 copies /var/lib/podium/data/podium.db
kubectl -n podium scale statefulset/podium --replicas=1
```

An upgrade changes `image.tag`; the StatefulSet stops the old pod before it
starts the new one, as one volume cannot serve both. A newer podium may write
state an older one cannot read: take a backup before you upgrade, as there is no
downgrade.

## Values

| Key | Default | |
| -- | -- | -- |
| `image.repository`, `image.tag`, `image.digest` | `ghcr.io/soltihq/podium`, `""`, `""` | `tag` defaults to `appVersion`; `digest` wins over it. |
| `secrets.existingSecret` | `""` | A Secret with the keys of `secrets.keys`. |
| `secrets.jwtSecret`, `secrets.enrollSecret`, `secrets.bootstrapAdminPassword` | `""` | For a Secret the chart makes, when `existingSecret` is empty. |
| `secrets.allowOpenEnrollment` | `false` | Allows running without an enrollment secret. |
| `config` | log at info as JSON, `shutdown_delay: 5s`, `shutdown_timeout: 15s` | podium's `podium.yaml`. |
| `tls.server.secretName`, `tls.server.clientCA.secretName` | `""` | TLS on 8080, 8082 and 50051; client certificates for agents. |
| `persistence.enabled`, `persistence.size`, `persistence.storageClass`, `persistence.existingClaim` | `true`, `1Gi`, `""`, `""` | Without persistence the state is lost with the pod. |
| `service.type`, `service.port` | `ClusterIP`, `8080` | The UI and the API. |
| `agents.service.type` | `ClusterIP` | HTTP discovery on 8082, gRPC on 50051. |
| `ops.service.enabled` | `true` | The ops listener's Service, for scraping and `helm test`. |
| `ingress.enabled` | `false` | The UI's Ingress. |
| `metrics.serviceMonitor.enabled` | `false` | A ServiceMonitor on the ops Service. |
| `extraEnv`, `extraEnvFrom`, `extraVolumes`, `extraVolumeMounts` | `[]` | `tls.client` files, for instance. |
| `resources` | requests 100m and 128Mi, limit 512Mi | |
| `terminationGracePeriodSeconds` | `60` | Covers the delay, the timeout and the store's close. |
