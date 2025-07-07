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
{{- if or (kindIs "bool" $v) (kindIs "float64" $v) (kindIs "int" $v) }}
  value: {{ $v }}
{{- else }}
  value: {{ $v | quote }}
  forceString: true
{{- end }}
{{- end }}
{{- end }}
{{- end }}
