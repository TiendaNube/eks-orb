#!/bin/bash

if [[ -z "${UPDATE_KUBECONFIG_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: UPDATE_KUBECONFIG_COMMON_SCRIPT is empty${NC}" >&2
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "${UPDATE_KUBECONFIG_COMMON_SCRIPT}")

if ! declare -f "update_kubeconfig" > /dev/null; then
  echo -e "${RED}❌ Error: update_kubeconfig function is not defined.${NC}" >&2
  exit 2
fi

update_kubeconfig "$@"
