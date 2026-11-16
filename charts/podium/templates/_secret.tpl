{{/*
The chart's Secret, from the secrets.* values, validated. It takes the root
context as "root" and the Secret's name as "name"; for the copy that a hook Job
brings (see "podium.hookJob"), the hook's events as "hook" and the Job's
component as "component".
*/}}
{{- define "podium.secret" -}}
{{- $v := .root.Values -}}
{{- $mode := include "podium.mode" .root -}}
{{- $jwt := required "secrets.jwtSecret is required, or name an existing Secret in secrets.existingSecret: generate it with openssl rand -hex 32" $v.secrets.jwtSecret }}
{{- if lt (len $jwt) 32 }}
{{- fail "secrets.jwtSecret must be 32 bytes or more: podium refuses a shorter one" }}
{{- end }}
{{- $enroll := $v.secrets.enrollSecret }}
{{- if and (not $enroll) (not $v.secrets.allowOpenEnrollment) }}
{{- fail "secrets.enrollSecret is required to close agent enrollment (openssl rand -hex 32); set secrets.allowOpenEnrollment=true to run without one" }}
{{- end }}
{{- if and $enroll (lt (len $enroll) 32) }}
{{- fail "secrets.enrollSecret must be 32 bytes or more: podium refuses a shorter one" }}
{{- end }}
{{- $admin := $v.secrets.bootstrapAdminPassword }}
{{- if and $admin (or (lt (len $admin) 12) (gt (len $admin) 72)) }}
{{- fail "secrets.bootstrapAdminPassword must be 12 characters to 72 bytes" }}
{{- end }}
{{- if and (eq $mode "database") (not $v.secrets.databaseUrl) }}
{{- fail "secrets.databaseUrl is required in database mode, or name an existing Secret in secrets.existingSecret with the key database-url" }}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .name }}
  labels:
    {{- include "podium.labels" .root | nindent 4 }}
    {{- with .component }}
    app.kubernetes.io/component: {{ . }}
    {{- end }}
  {{- if .hook }}
  annotations:
    helm.sh/hook: {{ .hook }}
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
  {{- end }}
type: Opaque
stringData:
  {{ $v.secrets.keys.jwtSecret }}: {{ $jwt | quote }}
  {{- with $enroll }}
  {{ $v.secrets.keys.enrollSecret }}: {{ . | quote }}
  {{- end }}
  {{- with $admin }}
  {{ $v.secrets.keys.bootstrapAdminPassword }}: {{ . | quote }}
  {{- end }}
  {{- if eq $mode "database" }}
  {{ $v.secrets.keys.databaseUrl }}: {{ $v.secrets.databaseUrl | quote }}
  {{- with $v.secrets.databaseReplicaUrl }}
  {{ $v.secrets.keys.databaseReplicaUrl }}: {{ . | quote }}
  {{- end }}
  {{- end }}
{{- end }}
