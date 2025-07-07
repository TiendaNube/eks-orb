{{- define "flatten" -}}
{{- $root := index . 0 -}}
{{- $prefix := index . 1 -}}
{{- range $k, $v := $root }}
{{- $name := "" -}}
{{- if eq $prefix "" -}}
{{- $name = $k -}}
{{- else -}}
{{- $name = printf "%s.%s" $prefix ($k | replace "." "\\.")  -}}
{{- end -}}
{{- if kindIs "map" $v }}
{{- include "flatten" (list $v $name) }}
{{- else if kindIs "slice" $v }}
{{- range $i, $item := $v }}
- name: {{ $name }}[{{ $i }}]
{{- include "formatValue" $item -}}
{{- end }}
{{- else }}
- name: {{ $name }}
{{- include "formatValue" $item -}}
{{- end }}
{{- end }}
{{- end }}
