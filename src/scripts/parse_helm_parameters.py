#!/usr/bin/python3

import re
import os

helm_parameters_input_file = os.environ.get("HELM_PARAMETERS_INPUT_FILE")
helm_parameters_output_file = os.environ.get("HELM_PARAMETERS_OUTPUT_FILE")

with open(helm_parameters_input_file, 'r') as f:
    helm_parameters = f.read()

# Improved regex to handle values with spaces (quoted or unquoted)
# This pattern captures everything after = until the next --set or end of string
pattern = r'(--set[^\s]*)\s+([^\s=]+(?:\.[^\s=]+)*)=([^-]*?)(?=\s+--set|\s*$)'
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

with open(helm_parameters_output_file, 'w') as f:
    for item in result:
        f.write(f"- name: {item['name']}\n  value: {item['value']}\n")
