{{/*
Resolves a full image reference from the shared registry + a per-service repository/tag pair.
Usage: {{ include "mini-arcade.image" (dict "registry" .Values.imageRegistry "repository" "auth-service" "tag" .Values.authService.tag) }}
*/}}
{{- define "mini-arcade.image" -}}
{{- .registry }}/{{ .repository }}:{{ .tag -}}
{{- end -}}
