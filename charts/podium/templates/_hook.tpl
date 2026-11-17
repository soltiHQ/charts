{{/*
The name of a hook's objects: the release's full name, cut so that the
component after it keeps the whole within 63 characters, and the component.
It takes the root context as "root" and the component as "component".
*/}}
{{- define "podium.hookName" -}}
{{- $base := include "podium.fullname" .root | trunc (int (sub 62 (len .component))) | trimSuffix "-" -}}
{{- printf "%s-%s" $base .component -}}
{{- end }}

{{/*
Whether helm uninstall drops the schema: "true" when dropSchema.onUninstall is
true, "" when it is false or unset. Anything but a boolean stops the render, in
every mode: a string such as "false", which --set-string or a quoted value
gives, would otherwise count as true, and drop the database at the uninstall.
*/}}
{{- define "podium.dropSchemaOnUninstall" -}}
{{- $values := default (dict) .Values.dropSchema -}}
{{- $on := false -}}
{{- if and (hasKey $values "onUninstall") (not (kindIs "invalid" $values.onUninstall)) -}}
{{- $on = $values.onUninstall -}}
{{- end -}}
{{- if not (kindIs "bool" $on) -}}
{{- fail (printf "dropSchema.onUninstall must be true or false, unquoted, not %q: a string such as \"false\" would count as true" (toString $on)) -}}
{{- end -}}
{{- if $on }}true{{ end -}}
{{- end }}

{{/*
A podium command as a Helm hook Job, podium migrate or podium drop-schema, with
copies of its own of the ConfigMap and, unless secrets.existingSecret names
one, of the chart's Secret, hooks too, from the same values: a pre-install hook
runs before the release's ConfigMap and Secret exist, a pre-upgrade one before
the new ones replace the old, and a post-delete one after the uninstall deleted
them. All three carry the component's label. When the Job succeeds, Helm
deletes the three. When it fails, or Helm's --timeout ends first, the Job stays,
for kubectl logs; Helm 3.18 and older keep the copies too, and Helm 3.19 and
later delete them.

It takes the root context as "root"; the component, which names the objects,
the container and the label, as "component"; the hook's events as "hook"; the
podium command and its arguments as "args"; the Job's limit, in seconds, as
"deadline"; and its retries as "backoffLimit".
*/}}
{{- define "podium.hookJob" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $name := include "podium.hookName" (dict "root" $root "component" .component) -}}
{{- $secret := default $name $v.secrets.existingSecret -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}
  labels:
    {{- include "podium.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
  annotations:
    helm.sh/hook: {{ .hook }}
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
data:
  podium.yaml: |
    {{- toYaml (default (dict) $v.config) | nindent 4 }}
{{- if not $v.secrets.existingSecret }}
---
{{ include "podium.secret" (dict "root" $root "name" $name "hook" .hook "component" .component) }}
{{- end }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $name }}
  labels:
    {{- include "podium.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
  annotations:
    helm.sh/hook: {{ .hook }}
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: {{ .backoffLimit }}
  activeDeadlineSeconds: {{ .deadline }}
  template:
    metadata:
      # Not the selector labels: the Services must never list this pod.
      labels:
        app.kubernetes.io/instance: {{ $root.Release.Name }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $v.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      restartPolicy: Never
      {{- with include "podium.hookServiceAccountName" $root }}
      serviceAccountName: {{ . }}
      {{- end }}
      automountServiceAccountToken: {{ $v.serviceAccount.automountServiceAccountToken }}
      {{- with $v.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml $v.podSecurityContext | nindent 8 }}
      {{- with include "podium.hookInitContainers" $root }}
      initContainers:
        {{- . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .component }}
          image: {{ include "podium.image" $root }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          args:
            {{- toYaml .args | nindent 12 }}
          env:
            {{- include "podium.env" (dict "root" $root "secret" $secret) | nindent 12 }}
          {{- with $v.extraEnvFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext:
            {{- toYaml $v.securityContext | nindent 12 }}
          volumeMounts:
            {{- include "podium.volumeMounts" $root | nindent 12 }}
      volumes:
        {{- include "podium.volumes" (dict "root" $root "config" $name) | nindent 8 }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
