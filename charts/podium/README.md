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
| Image | `ghcr.io/soltihq/podium`, the chart's `appVersion` (`v0.0.1-rc.2`) unless `image.tag` or `image.digest` says otherwise: the first podium release with both modes, `podium drop-schema` and `podium schema export`. Older images lack them |
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
  -n podium --set mode=database --set secrets.existingSecret=podium-secrets
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
  Secret does). With `tls.server` it forwards over TLS, and checks the leader's
  certificate for one name, `tls.forwardServerName`, by default the UI Service's
  `<release>.<namespace>.svc`, against the CA under `tls.server.caKey` of the
  same Secret, `ca.crt` by default: the replicas share the one certificate,
  which names that Service whatever their pod IPs, as in
  [Replicas over TLS](#replicas-over-tls). A follower that cannot verify the
  leader answers 502 to the write and logs why, at ERROR (`write not forwarded
  to the leader`). With `tls.server.clientCA`, every sync a follower forwards
  also needs a `tls.client` certificate from the agents' CA, through `extraEnv`
  (`SOLTI_TLS_CLIENT_CERT_FILE`, `SOLTI_TLS_CLIENT_KEY_FILE`). The chart issues
  neither certificate. At a rolling update a follower whose forward reaches no
  leader, as the leader's pod is gone, waits up to 3 seconds for the next leader
  and sends the write there. With `config.auth.rotate_refresh: true` a browser's
  refresh on a replica that does not lead answers 503, so route browsers to the
  leader (`/leaderz` on the ops port answers 200 on it only); leave rotation off
  otherwise.
- **Migrations.** `migrate.mode` says who migrates the schema. With `start`, the
  default, each replica migrates it at start, under a database lock, so replicas
  that start together migrate once. With `job` a Helm hook Job runs
  `podium migrate` before the install and before each upgrade, and the replicas
  get `SOLTI_CLUSTER_DATABASE_MIGRATE=false`: a replica then refuses an older
  schema.
  A `pre-install` hook runs before the release's ConfigMap and Secret exist, and a
  `pre-upgrade` one before the new ones replace the old, so the Job brings copies
  of both of its own, hooks too, from the same values (with
  `secrets.existingSecret` it reads that Secret, which must exist before the
  install); it migrates the database the new release will use, on install and on
  upgrade. The copies are deleted when the Job succeeds. When it fails the Job
  stays, for `kubectl logs`, and so do the copies with Helm 3.18 and older, while
  Helm 3.19 and later delete them. `--no-hooks` skips the Job, and the replicas
  then refuse the old schema.
  With `external` a tool of your own, as Bytebase, applies podium's migrations
  before the install and before each upgrade, the database first, then the
  release; the chart runs no Job, and the replicas get
  `SOLTI_CLUSTER_DATABASE_MIGRATE=false`. `podium schema export --dir DIR`
  writes an image's migrations out, and `podium schema version` prints the
  schema version it needs. Each file records its own version, so the replicas
  see what the tool applied. The database URL may then be a role that only reads
  and writes rows: podium's `migrations/README.md` lists its grants. The chart
  refuses `dropSchema.onUninstall` with `external`: the schema is that tool's to
  drop.
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

### Replicas over TLS

In the database mode one certificate serves every replica. It names the
Services, never a pod IP: a follower checks the leader's certificate for
`tls.forwardServerName`, the UI Service's name by default, against the CA in the
Secret's `tls.server.caKey`. With cert-manager and a CA issuer:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: podium-tls
  namespace: podium
spec:
  secretName: podium-tls            # tls.server.secretName
  issuerRef:
    name: podium-ca
    kind: Issuer
  dnsNames:
    - podium.podium.svc             # tls.forwardServerName's default, <release>.<namespace>.svc
    - podium-agents.podium.svc      # agents inside the cluster
    - podium.example.com            # the UI and the agents from outside, as you expose them
```

cert-manager writes the issuer's CA to `ca.crt`, the default of
`tls.server.caKey`. A certificate of a public CA, from an ACME issuer say, has
no `ca.crt`: set `tls.server.caKey: ""` and, as `tls.forwardServerName`, a name
of the certificate. The replicas then verify each other against the system
roots, unless `extraEnv` sets `SOLTI_TLS_CLIENT_CA_FILE` for agents of a private
CA: they fall back to that CA, and every write that reaches a follower fails.
In that case set `SOLTI_TLS_FORWARD_CA_FILE` to
`/etc/ssl/certs/ca-certificates.crt`, the system roots of podium's image, in
`extraEnv` too.

A Secret without the key that `tls.server.caKey` names fails the volume mount
(`references non-existent secret key`): no pod starts, neither the replicas nor
the migrate and drop-schema Jobs. With `migrate.mode: job`, `helm install` and
`helm upgrade` wait for the migrate hook until their `--timeout` and fail, and
the running replicas keep the previous revision. A name that the certificate
lacks fails every write that reaches a follower with 502, and the follower's log
says `certificate is valid for …, not …`.

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

## Containers beside podium

`initContainers` and `extraContainers` add containers to the pods of the
Deployment, as Kubernetes takes them, in both modes. An init container with
`restartPolicy: Always` is a native sidecar, which needs Kubernetes 1.29 or
later (the chart refuses one on an older cluster, which would run it as an init
container that never ends): it starts before podium, which waits for its
`startupProbe`, runs beside it, and stops after it. That is the form for a proxy
to the database, as podium keeps its connections through its shutdown, the
release of the lease included. A container of `extraContainers` runs beside
podium, started and stopped with it.

The hook Jobs, `migrate` (`migrate.mode: job`) and `drop-schema`
(`dropSchema.onUninstall`), take `initContainers` too, so that a proxy serves
them as it serves the replicas: a native sidecar stops once podium's command
ends, and the Job completes. `hooks.initContainers` replaces them for the Jobs
(`[]` for none), for an init container that needs an object of the release,
which exists neither before the install nor after the uninstall. The Jobs take
no `extraContainers`: a container beside podium would keep them from
completing.

The hook Jobs run under `hooks.serviceAccountName`; when it is empty, under
`serviceAccount.name` with `serviceAccount.create: false`, a ServiceAccount of
yours; otherwise under the namespace's `default`, as the release's own
ServiceAccount exists neither before the install nor after the uninstall. Their
pods mount its token as the replicas do, by
`serviceAccount.automountServiceAccountToken`.

### Cloud SQL on GKE

The [Cloud SQL Auth Proxy](https://github.com/GoogleCloudPlatform/cloud-sql-proxy)
as a native sidecar of the replicas and of the hook Jobs, with Workload
Identity: a Kubernetes ServiceAccount of yours, bound to a Google service
account with the Cloud SQL Client role, which the replicas and the Jobs run
under.

```yaml
serviceAccount:
  create: false
  name: podium
initContainers:
  - name: cloud-sql-proxy
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.28.0
    restartPolicy: Always
    args:
      - --private-ip
      - <project>:<region>:<instance>
    env:
      - name: CSQL_PROXY_PORT
        value: "5432"
      - name: CSQL_PROXY_HEALTH_CHECK
        value: "true"
      - name: CSQL_PROXY_HTTP_PORT
        value: "9801"
      - name: CSQL_PROXY_HTTP_ADDRESS
        value: 0.0.0.0
      - name: CSQL_PROXY_EXIT_ZERO_ON_SIGTERM
        value: "true"
      - name: CSQL_PROXY_STRUCTURED_LOGS
        value: "true"
    startupProbe:
      httpGet:
        path: /startup
        port: 9801
      periodSeconds: 1
      failureThreshold: 60
    livenessProbe:
      httpGet:
        path: /liveness
        port: 9801
      periodSeconds: 10
    securityContext:
      runAsNonRoot: true
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
```

- **The URL.** `database-url` names the proxy:
  `postgres://podium:<password>@127.0.0.1:5432/podium?sslmode=disable`. The
  proxy encrypts the connection to Cloud SQL and authorizes it with the
  service account. It is a TCP proxy, no pooler, so podium's `LISTEN`, which
  carries the events between the replicas, works through it.
- **No readiness probe on the proxy.** podium's `/readyz` already answers 503
  while the primary does not answer, through the proxy or not, and recovers
  with it.
- **The replicas' `podSecurityContext`** (user and group 65532, non-root)
  applies to the proxy too, whose image runs as a non-root user.
- **Workload Identity** goes through the GKE metadata server, which fetches the
  ServiceAccount's token itself, so the chart's default
  `automountServiceAccountToken: false` should not stand in its way; if your
  cluster needs the token in the pod, set it to `true`, for the replicas and
  the Jobs alike. With `serviceAccount.create: true` instead, the annotations of
  `serviceAccount` reach the replicas, but the hook Jobs run under the
  namespace's `default`, and the chart warns about it: name the bound
  ServiceAccount in `hooks.serviceAccountName`.
- **Without the Jobs.** With `migrate.mode: start` or `external` and no
  `dropSchema.onUninstall` there is no hook Job: the replicas alone need the
  proxy.
- `--private-ip` reaches the instance by its private IP; leave it out for a
  public one. `ci/database-cloudsql-values.yaml` renders this setup.

## Back up, upgrade

The memory mode has nothing to back up: the state is lost with the pod. In the
database mode the state is the database: back it up with its own tools, as the
chart neither runs nor backs up it.

An upgrade changes the image: a chart with a newer `appVersion`, or
`image.tag`. The memory mode's Deployment stops the old pod before it starts the
new one; the database mode's starts a new replica, ready, before an old one
stops (`maxSurge: 1`, `maxUnavailable: 0`). A newer podium may write state an
older one cannot read: take a backup before you upgrade, as there is no
downgrade.

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
brings the data back. The value must be `true` or `false` unquoted: anything
else, a string `"false"` that `--set-string` or a quoted value gives included,
stops the render, as a string would otherwise count as true. The hook is stored
with the release, so set the value with `helm install` or `helm upgrade` before
the uninstall:

```sh
helm upgrade podium oci://ghcr.io/soltihq/charts/podium --version 0.0.2 \
  -n podium --reset-then-reuse-values --set dropSchema.onUninstall=true
helm uninstall podium -n podium
```

`--reset-then-reuse-values` (Helm 3.14 or later) applies the chart's defaults
for the values the release did not set; plain `--reuse-values` keeps the old
chart's values alone, and the chart then falls back on its own defaults for the
`dropSchema` keys an older release lacks. With `migrate.mode: external` the
chart refuses `dropSchema.onUninstall`: drop the schema with the tool that
migrates it.

- **It waits for the replicas.** A `post-delete` hook can run while the pods
  still stop, as `helm uninstall` does not always wait for them to be gone. A
  replica counts as running while it heartbeated within the last three seconds,
  or while it holds an unexpired lease. One that stops cleanly deletes its row
  and releases the lease, so it stops counting at once; a killed follower stops
  counting three seconds after its last heartbeat, and a killed leader once its
  lease expires. Only replicas that run protect the database: a deployment that
  shares it but runs none at that moment, scaled to zero or restarting, does not
  keep it from being dropped.
- **One attempt, bounded by the wait.** The Job runs one pod
  (`backoffLimit: 0`; podium retries an unreachable database itself, for 30
  seconds). It waits up to `dropSchema.wait` (2m) for the replicas, and for a
  lock another session holds on a table, a `pg_dump` say; a replica that still
  runs then, one of another release on the same database say, fails the Job, and
  nothing is dropped. A database whose schema is newer than the image fails it
  too, as the image does not know the newer tables, and so do tables with
  podium's names in a database podium never migrated.
- **Helm's timeout.** `dropSchema.activeDeadlineSeconds` (240) bounds the Job,
  and `helm uninstall` waits for it up to its `--timeout`, 5 minutes by default:
  keep `--timeout` above the deadline plus the time to schedule the pod and pull
  the image. An uninstall whose `--timeout` ended first reports a failure, while
  the Job runs on and can still drop the schema once the replicas stop: wait for
  the Job to complete or fail, or delete it, before you install again on that
  database.
- **What it needs at the uninstall.** The release's ConfigMap and Secret are
  gone by then, so the Job brings copies of both, hooks too, from the release's
  values. Everything else the pod refers to must still exist: the Secret of
  `secrets.existingSecret`, the TLS Secrets of `tls.server`, the objects that
  `extraVolumes` and `extraEnvFrom` name, and the `imagePullSecrets`; a pod that
  lacks one never starts, and nothing is dropped. The role of the database URL
  must own the tables, as the role that created them does.
- **A failed Job stays**, for `kubectl logs`. Helm 3.18 and older keep its
  ConfigMap and Secret copies too; Helm 3.19 and later delete them when the Job
  fails. `helm uninstall` reports the hook's failure but deletes the release all
  the same, so a retry is yours: run `podium drop-schema --yes` once the cause
  is fixed. A copy of the chart's Secret holds the database URL and the other
  secrets: delete what is left once you are done, `kubectl -n podium delete
  job,configmap,secret -l
  app.kubernetes.io/instance=podium,app.kubernetes.io/component=drop-schema`.
- `helm uninstall --no-hooks` skips it, and the memory mode, which has no
  database, never runs it.

## Values

| Key | Default | |
| -- | -- | -- |
| `mode` | `memory` | `memory`, or `database`. |
| `replicas` | `2` | The database mode's replicas; the memory mode runs one. |
| `image.repository`, `image.tag`, `image.digest` | `ghcr.io/soltihq/podium`, `""`, `""` | `tag` defaults to `appVersion`; `digest` wins over it. |
| `secrets.existingSecret` | `""` | A Secret with the keys of `secrets.keys`. |
| `secrets.jwtSecret`, `secrets.enrollSecret`, `secrets.bootstrapAdminPassword` | `""` | For a Secret the chart makes, when `existingSecret` is empty. |
| `secrets.databaseUrl`, `secrets.databaseReplicaUrl` | `""` | Database mode: the primary (required with the chart's own Secret) and the optional read endpoint; the keys `database-url` and `database-replica-url` of an existing Secret. |
| `migrate.mode`, `migrate.job.activeDeadlineSeconds` | `start`, `600` | Database mode: who migrates the schema: each replica at start (`start`), `podium migrate` as a pre-install and pre-upgrade hook (`job`), or a tool of your own (`external`). |
| `dropSchema.onUninstall`, `dropSchema.wait`, `dropSchema.activeDeadlineSeconds` | `false`, `2m`, `240` | Database mode: `podium drop-schema` as a post-delete hook, which drops podium's tables, and all of its data, at `helm uninstall` ([Uninstall](#uninstall)). |
| `secrets.allowOpenEnrollment` | `false` | Allows running without an enrollment secret. |
| `config` | log at info as JSON, `shutdown_delay: 5s`, `shutdown_timeout: 15s` | podium's `podium.yaml`. |
| `tls.server.secretName`, `tls.server.clientCA.secretName` | `""` | TLS on 8080, 8082 and 50051; client certificates for agents. |
| `tls.server.caKey`, `tls.forwardServerName` | `ca.crt`, `""` | Database mode: the CA in that Secret, and the name, the UI Service's by default, against which and for which a follower checks the leader ([Replicas over TLS](#replicas-over-tls)). |
| `service.type`, `service.port` | `ClusterIP`, `8080` | The UI and the API. |
| `agents.service.type` | `ClusterIP` | HTTP discovery on 8082, gRPC on 50051. |
| `ops.service.enabled` | `true` | The ops listener's Service, for scraping and `helm test`. |
| `ingress.enabled` | `false` | The UI's Ingress. |
| `metrics.serviceMonitor.enabled` | `false` | A ServiceMonitor on the ops Service. |
| `extraEnv`, `extraEnvFrom`, `extraVolumes`, `extraVolumeMounts` | `[]` | `tls.client` files, for instance. |
| `initContainers`, `extraContainers` | `[]` | Containers before and beside podium; an init container with `restartPolicy: Always` is a native sidecar, Kubernetes 1.29 or later ([Containers beside podium](#containers-beside-podium)). |
| `hooks.initContainers`, `hooks.serviceAccountName` | `null`, `""` | The hook Jobs' init containers, `initContainers` when null, and their ServiceAccount, `serviceAccount.name` with `serviceAccount.create: false` when empty, the namespace's `default` otherwise. |
| `resources` | requests 100m and 128Mi, limit 512Mi | |
| `terminationGracePeriodSeconds` | `60` | Covers the delay, the timeout and the store's close. |
