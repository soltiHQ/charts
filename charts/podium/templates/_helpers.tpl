{{/* The chart name, cut to 63 characters. */}}
{{- define "podium.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The release's full name, cut to 63 characters. */}}
{{- define "podium.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "podium.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "podium.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "podium.selectorLabels" -}}
app.kubernetes.io/name: {{ include "podium.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "podium.labels" -}}
helm.sh/chart: {{ include "podium.chart" . }}
{{ include "podium.selectorLabels" . }}
app.kubernetes.io/version: {{ include "podium.imageTag" . | trunc 63 | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "podium.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "podium.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
The ServiceAccount the hook Jobs run as: hooks.serviceAccountName, or, with
serviceAccount.create false, the one the replicas run as, which exists apart
from the release; empty otherwise, for the namespace's default. The release's
own ServiceAccount exists neither when the pre-install Job runs, before the
release's objects, nor when the post-delete one runs, after the uninstall.
*/}}
{{- define "podium.hookServiceAccountName" -}}
{{- $hooks := default (dict) .Values.hooks -}}
{{- if $hooks.serviceAccountName -}}
{{- $hooks.serviceAccountName -}}
{{- else if not .Values.serviceAccount.create -}}
{{- include "podium.serviceAccountName" . -}}
{{- end -}}
{{- end }}

{{/*
A list of containers from the values, as YAML for a pod's containers or
initContainers, empty for none. It takes the list as "value", its key, which a
failure names, as "key", and the cluster's version as "kubeVersion". A value
that is not a list stops the render, and so does a native sidecar, a container
with restartPolicy Always, on a Kubernetes older than 1.29, which would drop
the field and run it as an init container that never ends.
*/}}
{{- define "podium.containerList" -}}
{{- $value := .value -}}
{{- if not (or (kindIs "invalid" $value) (kindIs "slice" $value)) -}}
{{- fail (printf "%s must be a list of containers, not a %s" .key (kindOf $value)) -}}
{{- end -}}
{{- range $value -}}
{{- if and (kindIs "map" .) (eq (toString (get . "restartPolicy")) "Always") (semverCompare "<1.29.0-0" $.kubeVersion) -}}
{{- fail (printf "%s: %v, a native sidecar (restartPolicy Always), needs Kubernetes 1.29 or later, not %s" $.key (get . "name") $.kubeVersion) -}}
{{- end -}}
{{- end -}}
{{- if $value -}}
{{- toYaml $value -}}
{{- end -}}
{{- end }}

{{/*
The init containers of the hook Jobs, as podium.containerList renders them:
hooks.initContainers when it is a list, even an empty one, and otherwise those
of initContainers. A native sidecar among them, a proxy to the database say,
serves the Job as it serves the replicas and stops once podium's command ends,
so that the Job completes; a container beside podium would keep it from
completing, and the Jobs take none.
*/}}
{{- define "podium.hookInitContainers" -}}
{{- $hooks := default (dict) .Values.hooks -}}
{{- $key := "initContainers" -}}
{{- $value := .Values.initContainers -}}
{{- if and (hasKey $hooks "initContainers") (not (kindIs "invalid" $hooks.initContainers)) -}}
{{- $key = "hooks.initContainers" -}}
{{- $value = $hooks.initContainers -}}
{{- end -}}
{{- include "podium.containerList" (dict "key" $key "value" $value "kubeVersion" .Capabilities.KubeVersion.Version) -}}
{{- end }}

{{- define "podium.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "podium.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (include "podium.imageTag" .) }}
{{- end }}
{{- end }}

{{/* The Secret podium's environment comes from. */}}
{{- define "podium.secretName" -}}
{{- default (include "podium.fullname" .) .Values.secrets.existingSecret }}
{{- end }}

{{/* The mode, memory or database; anything else stops the render. */}}
{{- define "podium.mode" -}}
{{- $mode := default "memory" .Values.mode -}}
{{- if not (has $mode (list "memory" "database")) -}}
{{- fail (printf "mode must be memory or database, not %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end }}

{{/*
Who migrates the schema of the database mode, migrate.mode: start, each replica
at its start; job, the hook Job of migrate.yaml before each install and upgrade;
external, a tool of the deployment's own, as Bytebase, before the release, out
of the chart's sight. With job and external the replicas do not migrate. Any
other value stops the render, and so does migrate.job.enabled, which the
previews of this chart had before migrate.mode.
*/}}
{{- define "podium.migrateMode" -}}
{{- $values := default (dict) .Values.migrate -}}
{{- if hasKey (default (dict) $values.job) "enabled" -}}
{{- fail "migrate.job.enabled is replaced by migrate.mode: set migrate.mode to job for the hook Job" -}}
{{- end -}}
{{- $mode := "start" -}}
{{- if and (hasKey $values "mode") (not (kindIs "invalid" $values.mode)) -}}
{{- $mode = $values.mode -}}
{{- end -}}
{{- if not (has $mode (list "start" "job" "external")) -}}
{{- fail (printf "migrate.mode must be start, job or external, not %q" (toString $mode)) -}}
{{- end -}}
{{- $mode -}}
{{- end }}

{{/*
The name a follower checks the leader's certificate for, in the database mode
with tls.server: tls.forwardServerName, or the UI Service's name. A name that is
not a DNS name stops the render, as podium would refuse it at start.
*/}}
{{- define "podium.forwardServerName" -}}
{{- $tls := default (dict) .Values.tls -}}
{{- $name := default (printf "%s.%s.svc" (include "podium.fullname" .) .Release.Namespace) (toString (default "" $tls.forwardServerName)) -}}
{{- if or (gt (len $name) 253) (not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$" $name)) -}}
{{- fail (printf "tls.forwardServerName must be a DNS name, not %q" $name) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{/*
The key of the tls.server Secret that holds the CA of its certificate, against
which a follower checks the leader's certificate in the database mode:
tls.server.caKey, "" for none, and ca.crt when the key is unset, as in the
values of a release made before it existed, which --reuse-values keeps.
*/}}
{{- define "podium.forwardCAKey" -}}
{{- $server := default (dict) (default (dict) .Values.tls).server -}}
{{- if hasKey $server "caKey" -}}
{{- toString (default "" $server.caKey) -}}
{{- else -}}
ca.crt
{{- end -}}
{{- end }}

{{/*
The environment of the server and of the hook Jobs, which load the same
configuration. It takes the root context as "root" and the Secret to read as
"secret". The database URLs reach the pod only as secretKeyRef, never as a
literal or from the ConfigMap.
*/}}
{{- define "podium.env" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $mode := include "podium.mode" $root -}}
- name: SOLTI_CLUSTER_BACKEND
  value: {{ $mode }}
{{- if eq $mode "database" }}
- name: SOLTI_CLUSTER_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ $v.secrets.keys.databaseUrl }}
- name: SOLTI_CLUSTER_DATABASE_REPLICA_URL
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ $v.secrets.keys.databaseReplicaUrl }}
      optional: true
{{- end }}
- name: SOLTI_AUTH_JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ $v.secrets.keys.jwtSecret }}
- name: SOLTI_AGENT_AUTH_ENROLL_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ $v.secrets.keys.enrollSecret }}
      optional: {{ $v.secrets.allowOpenEnrollment }}
- name: SOLTI_BOOTSTRAP_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ $v.secrets.keys.bootstrapAdminPassword }}
      optional: true
{{- if $v.tls.server.secretName }}
- name: SOLTI_TLS_SERVER_CERT_FILE
  value: /etc/podium-tls/server/tls.crt
- name: SOLTI_TLS_SERVER_KEY_FILE
  value: /etc/podium-tls/server/tls.key
{{- if eq $mode "database" }}
- name: SOLTI_TLS_FORWARD_SERVER_NAME
  value: {{ include "podium.forwardServerName" $root | quote }}
{{- with include "podium.forwardCAKey" $root }}
- name: SOLTI_TLS_FORWARD_CA_FILE
  value: /etc/podium-tls/server/{{ . }}
{{- end }}
{{- end }}
{{- end }}
{{- if $v.tls.server.clientCA.secretName }}
- name: SOLTI_TLS_SERVER_CLIENT_CA_FILE
  value: /etc/podium-tls/client-ca/{{ $v.tls.server.clientCA.key }}
{{- end }}
{{- with $v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* The mounts that go with "podium.env" and "podium.volumes". */}}
{{- define "podium.volumeMounts" -}}
- name: config
  mountPath: /etc/podium
  readOnly: true
{{- if .Values.tls.server.secretName }}
- name: tls-server
  mountPath: /etc/podium-tls/server
  readOnly: true
{{- end }}
{{- if .Values.tls.server.clientCA.secretName }}
- name: tls-client-ca
  mountPath: /etc/podium-tls/client-ca
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* The volumes, with the ConfigMap "config" to mount. */}}
{{- define "podium.volumes" -}}
{{- $v := .root.Values -}}
- name: config
  configMap:
    name: {{ .config }}
{{- if $v.tls.server.secretName }}
- name: tls-server
  secret:
    secretName: {{ $v.tls.server.secretName }}
    items:
      - key: tls.crt
        path: tls.crt
      - key: tls.key
        path: tls.key
{{- $caKey := include "podium.forwardCAKey" .root }}
{{- if and (eq (include "podium.mode" .root) "database") $caKey (ne $caKey "tls.crt") }}
      - key: {{ $caKey }}
        path: {{ $caKey }}
{{- end }}
{{- end }}
{{- if $v.tls.server.clientCA.secretName }}
- name: tls-client-ca
  secret:
    secretName: {{ $v.tls.server.clientCA.secretName }}
    items:
      - key: {{ $v.tls.server.clientCA.key }}
        path: {{ $v.tls.server.clientCA.key }}
{{- end }}
{{- with $v.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}
