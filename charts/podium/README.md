# podium

This chart runs [podium](https://github.com/soltiHQ/podium), the solti control
plane, in one of two modes, chosen by `mode`:

| `mode` | State | Runs |
| -- | -- | -- |
| `memory` (default) | In the pod's memory, lost with the pod | One replica, a Deployment that stops the old pod before it starts the new one, no volume |
| `database` | In a Postgres database you provide | `replicas` (default 2) of a Deployment that rolls without losing a replica; the replicas share the database, elect their leader through it, and forward their writes to it |

A raft cluster is not covered. Changing the mode of a release changes where the
state lives; nothing moves from one to the other.

| | |
| -- | -- |
| Image | `ghcr.io/soltihq/podium`, the chart's `appVersion` (`v0.0.1-rc.1`) unless `image.tag` or `image.digest` says otherwise. Both modes need an image newer than the `appVersion`, which predates them: the memory mode one with podium's `memory` backend, the database mode one with its `database` backend. Set `image.tag` or `image.digest`; the release that publishes the chart sets `appVersion` |
| Kubernetes | 1.25 or later |
| Helm | 3.8 or later |

## Install

The default mode, `memory`, is for trying podium out; the database mode has its
[own section](#database-mode). Create the secrets podium needs, and keep their values somewhere safe: a
changed enrollment secret locks out every agent enrolled under the old one,
and a changed JWT secret ends every session.

```sh
kubectl create namespace podium
kubectl -n podium create secret generic podium-secrets \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=enroll-secret="$(openssl rand -hex 32)" \
  --from-literal=bootstrap-admin-password='<12 characters to 72 bytes>'

helm install podium oci://ghcr.io/soltihq/charts/podium --version 0.0.2 \
  -n podium --set secrets.existingSecret=podium-secrets
```

From a checkout of this repository, `./charts/podium` takes the place of the
OCI reference.

The chart can make the Secret itself from `secrets.jwtSecret`,
`secrets.enrollSecret` and `secrets.bootstrapAdminPassword` instead, but then
the values live in your Helm values and release history. It never generates
them: a value that changed at an upgrade would lock the agents out.

`bootstrap-admin-password` is the password of the first administrator, `admin`.
In the memory mode each start seeds the administrator again, from it when it is
set and from a random password that podium logs once at WARN (`kubectl logs`)
when it is not: keep the key for one password across restarts, as the state, a
changed password included, is lost with the pod, and podium never warns about
the key there. In the database mode an empty database needs it: without it the
replicas stop at start. Once users exist podium ignores it, and the leader warns
about it at the start of each of its terms: log in, change the password, then
remove the key and restart:

```sh
kubectl -n podium patch secret podium-secrets --type=json \
  -p='[{"op":"remove","path":"/data/bootstrap-admin-password"}]'
kubectl -n podium rollout restart deployment/podium
```

## Database mode

```sh
kubectl -n podium create secret generic podium-secrets \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=enroll-secret="$(openssl rand -hex 32)" \
  --from-literal=bootstrap-admin-password='<12 characters to 72 bytes>' \
  --from-literal=database-url='postgres://podium:<password>@db.example.com:5432/podium?sslmode=verify-full' \
  --from-literal=database-replica-url='postgres://podium_ro:<password>@db-replica.example.com:5432/podium?sslmode=verify-full'

helm install podium oci://ghcr.io/soltihq/charts/podium --version 0.0.2 \
  -n podium --set mode=database --set secrets.existingSecret=podium-secrets \
  --set image.tag=<a release with the database mode>
```

- **The URLs.** `database-url` is the primary and `database-replica-url`, which
  is optional, a read endpoint for the lists of the UI and the API. They carry
  the password, so keep them in the Secret: they reach the pods only as
  `secretKeyRef` environment variables (`SOLTI_CLUSTER_DATABASE_URL`,
  `SOLTI_CLUSTER_DATABASE_REPLICA_URL`), never in the ConfigMap or as a literal.
  With the chart's own Secret instead, set `secrets.databaseUrl` and
  `secrets.databaseReplicaUrl`, and they live in your Helm values and release
  history. The chart never generates them. TLS to the database goes through the
  URL (`sslmode=verify-full`, `sslrootcert`).
- **The read role.** The role of `database-replica-url` (`podium_ro` above) needs
  `USAGE` on podium's schema and `SELECT` on its tables, with default privileges
  for the tables later migrations add (`ALTER DEFAULT PRIVILEGES FOR ROLE <owner>
  IN SCHEMA <schema> GRANT SELECT ON TABLES TO <role>`, run for the role that
  owns them), and it must resolve the same schema (`ALTER ROLE <role> SET
  search_path = <schema>`). Without them every GET listing answers 500: podium
  falls back to the primary only when the read endpoint is unreachable, not when
  it refuses a statement.
- **The database.** The role needs to create tables in its schema. `LISTEN`,
  which podium uses to share events, needs a direct or session-mode connection:
  not PgBouncer's transaction mode. Synchronous replication is recommended: rows
  a failover from an asynchronous standby loses are lost. Settings such as
  `lease` and `max_open_conns` go in `config.cluster.database`; each replica
  holds up to `max_open_conns` + 2 connections to the primary and up to
  `max_open_conns` to the replica, a rolling update briefly one more pod, so
  keep them under the server's `max_connections`. The full list is in
  [Database backend](https://github.com/soltiHQ/podium/blob/main/internal/config/README.md#database-backend).
- **The advertise address.** The chart sets `SOLTI_CLUSTER_DATABASE_ADVERTISE_ADDR`
  to `[$(POD_IP)]:8080`, the pod IP from the downward API. podium wants
  `host:port` with an IPv6 host in brackets; it accepts a bracketed IPv4 host too,
  and its forwarding strips the brackets, so the one form serves IPv4 and IPv6
  pods, where `$(POD_IP):8080` would be invalid for IPv6. podium takes the host
  to forward to, at the ports every replica serves; the port is not used.
- **Forwarding.** A replica that does not lead forwards the writes it gets to the
  leader, logins and tokens included, in plaintext without `tls.server`, with one
  WARN at start; give every replica the same `jwt-secret` and `enroll-secret` (the
  Secret does). With `tls.server` a follower checks the leader's certificate
  against the leader's advertise host as written, here the pod IP, so every
  pod's certificate needs that pod's IP as a SAN, or the follower answers 502.
  One static Secret cannot name a Deployment's changing pod IPs: use per-pod
  certificates, from cert-manager's CSI driver for example, mounted through
  `extraVolumes` and `extraVolumeMounts` and pointed at by `extraEnv`
  (`SOLTI_TLS_SERVER_CERT_FILE`, `SOLTI_TLS_SERVER_KEY_FILE`; the chart's
  `tls.server.secretName` mounts one Secret, which does not fit). With
  `tls.server.clientCA`, every sync a follower forwards also needs a `tls.client`
  certificate from the agents' CA, through `extraEnv`
  (`SOLTI_TLS_CLIENT_CERT_FILE`, `SOLTI_TLS_CLIENT_KEY_FILE`). The chart issues
  neither certificate. With `config.auth.rotate_refresh: true` a browser's
  refresh on a replica that does not lead answers 503, so route browsers to the
  leader (`/leaderz` on the ops port answers 200 on it only); leave rotation off
  otherwise.
- **Migrations.** By default each replica migrates the schema at start, under a
  database lock, so replicas that start together migrate once. With
  `migrate.job.enabled: true` a Helm hook Job runs `podium migrate` before the
  install and before each upgrade, and the replicas get
  `SOLTI_CLUSTER_DATABASE_MIGRATE=false`: a replica then refuses an older schema.
  A `pre-install` hook runs before the release's ConfigMap and Secret exist, and a
  `pre-upgrade` one before the new ones replace the old, so the Job brings copies
  of both of its own, hooks too, from the same values (with
  `secrets.existingSecret` it reads that Secret, which must exist before the
  install); it migrates the database the new release will use, on install and on
  upgrade. The copies are deleted when the Job succeeds, and stay, with the Job,
  when it fails, for `kubectl logs`. `--no-hooks` skips the Job, and the replicas
  then refuse the old schema.
- **Uninstall.** `helm uninstall` leaves the database as it is, unless
  `dropSchema.onUninstall` drops podium's tables with it: see
  [Uninstall](#uninstall).
- **Upgrades.** A release's migrations only add, so the version before keeps
  working while a rollout runs. A database whose schema is newer than the image
  stops the replicas that start (a rollback past a migration, or two versions
  in a rollout). There is no downgrade: take a database backup before you upgrade.
  The chart neither runs nor backs up the database.
- **The password.** Postgres keeps the sessions it authenticated before an
  `ALTER ROLE … PASSWORD`, and podium reads the URLs at start and sets no
  connection lifetime. To rotate: update the Secret's URL keys, then
  `kubectl rollout restart deployment/podium`. Between the `ALTER ROLE` and the
  restart each new connection fails with 28P01, so a short window of errors
  is to be expected; the rolling restart ends it.
- **Rate limits** are per replica, in memory, not shared through the database.

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
kubectl -n podium exec deploy/podium -- /podium agent-token agent-1
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

## Configuration

`config` is podium's `podium.yaml`, mounted read-only and passed with
`--config`. podium loads it strictly: a key that is not a setting, or a key
without a value, stops it at start, with the line. The environment wins over
the file, and each setting the environment overrides is logged at INFO. The
chart sets `SOLTI_CLUSTER_BACKEND`, in the database mode the database URLs
and the advertise address as well, and the image sets `SOLTI_OPS_ADDR=:8081`. The chart assumes podium's default listener ports: 8080,
8081, 8082 and 50051. See
[every setting](https://github.com/soltiHQ/podium/blob/main/internal/config/README.md#every-setting).

## Back up, upgrade

The memory mode has nothing to back up: the state is lost with the pod. In the
database mode the state is the database: back it up with its own tools, as the
chart neither runs nor backs up it.

An upgrade changes `image.tag`. The memory mode's Deployment stops the old pod
before it starts the new one; the database mode's starts a new replica, ready,
before an old one stops (`maxSurge: 1`, `maxUnavailable: 0`). A newer podium may
write state an older one cannot read: take a backup before you upgrade, as there
is no downgrade.

### From chart 0.0.1

Chart 0.0.1 ran a StatefulSet with a PersistentVolumeClaim `data-<fullname>-0`.
This chart has a Deployment instead, so an upgrade replaces the StatefulSet and
leaves its claim in place, unused: delete it yourself
(`kubectl delete pvc data-podium-0`) once you no longer need the state in it. The
state itself does not carry over: the standalone mode it held is gone from
podium, and `values.yaml` has no `persistence` any more. The `<fullname>-headless`
Service is gone too.

## Uninstall

`helm uninstall` deletes the release's objects. In the database mode it leaves
the database as it is by default: podium's tables, and the state in them, stay,
and a later install on the same database finds them.

With `dropSchema.onUninstall: true` the uninstall drops them too. A Helm hook
Job runs `podium drop-schema` once Helm has deleted the release's objects: it
waits until no replica runs on the database, then drops every table of
podium's, and all of its data, in one transaction. It drops nothing else: no
other table, no schema of the database's, not the database. Only a backup
brings the data back. The hook is stored with the release, so set the value
with `helm install` or `helm upgrade` before the uninstall:

```sh
helm upgrade podium oci://ghcr.io/soltihq/charts/podium --version 0.0.2 \
  -n podium --reuse-values --set dropSchema.onUninstall=true
helm uninstall podium -n podium
```

- **It waits for the replicas.** A `post-delete` hook can run while the pods
  still stop, as `helm uninstall` does not always wait for them to be gone. A
  replica counts as running while it heartbeated within the last three
  seconds or holds an unexpired lease: one that stops cleanly deletes its row
  and releases the lease, and one that is killed runs until its lease expires.
  `dropSchema.wait` (2m) bounds the wait: a replica that still runs then, one of
  another release on the same database say, fails the Job, and nothing is
  dropped. A database whose schema is newer than the image fails it too, as the
  image does not know the newer tables. `dropSchema.activeDeadlineSeconds` (240)
  bounds the Job, and `helm uninstall` waits for it up to its `--timeout`, 5
  minutes by default.
- **It brings its own configuration.** The release's ConfigMap and Secret are
  gone by then, so the Job brings copies of both, hooks too, from the release's
  values; with `secrets.existingSecret` it reads that Secret, which must still
  exist.
- **A failed Job stays**, with its copies, for `kubectl logs`. `helm uninstall`
  reports the hook's failure but deletes the release all the same, so a retry is
  yours: run `podium drop-schema --yes` once the cause is fixed. The copy of the
  chart's Secret holds the database URL and the other secrets: delete what is
  left once you are done, `kubectl -n podium delete job,configmap,secret -l
  app.kubernetes.io/instance=podium,app.kubernetes.io/component=drop-schema`.
- `helm uninstall --no-hooks` skips it, and the memory mode, which has no
  database, never runs it. It needs an image with `podium drop-schema`.

## Values

| Key | Default | |
| -- | -- | -- |
| `mode` | `memory` | `memory`, or `database`. |
| `replicas` | `2` | The database mode's replicas; the memory mode runs one. |
| `image.repository`, `image.tag`, `image.digest` | `ghcr.io/soltihq/podium`, `""`, `""` | `tag` defaults to `appVersion`; `digest` wins over it. |
| `secrets.existingSecret` | `""` | A Secret with the keys of `secrets.keys`. |
| `secrets.jwtSecret`, `secrets.enrollSecret`, `secrets.bootstrapAdminPassword` | `""` | For a Secret the chart makes, when `existingSecret` is empty. |
| `secrets.databaseUrl`, `secrets.databaseReplicaUrl` | `""` | Database mode: the primary (required with the chart's own Secret) and the optional read endpoint; the keys `database-url` and `database-replica-url` of an existing Secret. |
| `migrate.job.enabled`, `migrate.job.activeDeadlineSeconds` | `false`, `600` | Database mode: `podium migrate` as a pre-install and pre-upgrade hook. |
| `dropSchema.onUninstall`, `dropSchema.wait`, `dropSchema.activeDeadlineSeconds` | `false`, `2m`, `240` | Database mode: `podium drop-schema` as a post-delete hook, which drops podium's tables, and all of its data, at `helm uninstall` ([Uninstall](#uninstall)). |
| `secrets.allowOpenEnrollment` | `false` | Allows running without an enrollment secret. |
| `config` | log at info as JSON, `shutdown_delay: 5s`, `shutdown_timeout: 15s` | podium's `podium.yaml`. |
| `tls.server.secretName`, `tls.server.clientCA.secretName` | `""` | TLS on 8080, 8082 and 50051; client certificates for agents. |
| `service.type`, `service.port` | `ClusterIP`, `8080` | The UI and the API. |
| `agents.service.type` | `ClusterIP` | HTTP discovery on 8082, gRPC on 50051. |
| `ops.service.enabled` | `true` | The ops listener's Service, for scraping and `helm test`. |
| `ingress.enabled` | `false` | The UI's Ingress. |
| `metrics.serviceMonitor.enabled` | `false` | A ServiceMonitor on the ops Service. |
| `extraEnv`, `extraEnvFrom`, `extraVolumes`, `extraVolumeMounts` | `[]` | `tls.client` files, for instance. |
| `resources` | requests 100m and 128Mi, limit 512Mi | |
| `terminationGracePeriodSeconds` | `60` | Covers the delay, the timeout and the store's close. |
