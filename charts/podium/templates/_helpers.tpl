{{/* The chart name, cut to 63 characters. */}}
{{- define "podium.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The release's full name, cut to 63 characters. */}}
{{- define "podium.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
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

{{/*
The volume is mounted at /var/lib/podium, and podium keeps its state in a
directory below it that it makes itself, mode 0700. The volume's own root may
carry group or other permissions (fsGroup, or a hostPath provisioner that makes
it 0777), which podium refuses on its data directory.
*/}}
{{- define "podium.dataDir" -}}
/var/lib/podium/data
{{- end }}
