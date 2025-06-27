#!/usr/bin/python3

import re
import os

helm_parameters_input_file = os.environ.get("HELM_PARAMETERS_INPUT_FILE")
helm_parameters_output_file = os.environ.get("HELM_PARAMETERS_OUTPUT_FILE")

allowed_opts = {"set", "set-string"}

pattern = re.compile(
    r'--(?P<opt>set(?:-string)?)\s+(?P<key>[^\s=]+)=(?P<value>(?:(?!--set(?:-string)?\s).)+)',
    re.DOTALL
)

def infer_type(value: str):
    if value.startswith('"') and value.endswith('"'):
        return value
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    if re.match(r"^-?\d+$", value):
        return int(value)
    if re.match(r"^-?\d+\.\d+$", value):
        return float(value)
    return value

def clean_key(key: str) -> str:
    # Remove only quotes, preserve backslashes
    return key.replace('"', '').replace("'", "")

def parse_helm_set_args():
    with open(helm_parameters_input_file, 'r') as f:
        helm_parameters = f.read()

    flattened = helm_parameters.replace("\\\n", " ")

    results = []
    for match in pattern.finditer(flattened):
        opt, key, value = match.groups()
        if opt not in allowed_opts:
            raise ValueError(f"Invalid option: --{opt}. Only --set and --set-string are allowed.")

        key = clean_key(key)
        is_string = opt == 'set-string'
        parsed_value = value if is_string else infer_type(value)
        results.append({'name': key, 'value': parsed_value})

    return results

if __name__ == "__main__":
    parsed = parse_helm_set_args()
    with open(helm_parameters_output_file, 'w') as f:
        for item in parsed:
            f.write(f"- name: {item['name']}\n  value: {item['value']}\n")
