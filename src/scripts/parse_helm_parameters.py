#!/usr/bin/python3

import re
import os

helm_parameters = os.environ.get("HELM_PARAMETERS", "")

pattern = r'(--set[^\s]*)\s+([^\s=]+|[^\s=]+\.\"[^\"]+\")=([^\s\\]+)'
matches = re.findall(pattern, helm_parameters)

allowed_opts = {'--set', '--set-string'}

result = []
for opt, key, value in matches:
    if opt not in allowed_opts:
        raise ValueError(f"Invalid option: {opt}. Only --set and --set-string are allowed.")
    key = key.replace('"', '')
    if opt == '--set-string':
        value = f'"{value}"'
    result.append({'name': key, 'value': value})

with open('/tmp/helm-args.yaml', 'w') as f:
    for item in result:
        f.write(f"- name: {item['name']}\n  value: {item['value']}\n")
