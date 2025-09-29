#!/bin/bash

# Script to check the status of an Argo Rollout release
#
# Usage: Set the following environment variables:
#   ROLLOUT_NAME                  - The rollout name to check
#   NAMESPACE                     - The namespace to check
#   ROLLOUT_STATUS_TIMEOUT        - Timeout in seconds
#   ROLLOUT_STATUS_CHECK_INTERVAL - Interval between checks in seconds
#   ROLLOUT_STATUS_COMMON_SCRIPT  - The script to source for reusable status check functions
#   ARGO_CLI_COMMON_SCRIPT        - The script to source for reusable Argo CLI functions
#
# Returns:
#   - Exit code 0 if rollout is Healthy or Completed, or if timeout is reached
#   - Exit code 1 if rollout is Degraded, Error, or Aborted
#   - Exit code 2 for script errors

# Colors for output
RED="\033[0;31m"
NC="\033[0m" # No Color

if [[ -z "${ROLLOUT_STATUS_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: ROLLOUT_STATUS_COMMON_SCRIPT is empty${NC}" >&2
  exit 2
fi

if [[ -z "${ARGO_CLI_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: ARGO_CLI_COMMON_SCRIPT is empty${NC}" >&2
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "${ROLLOUT_STATUS_COMMON_SCRIPT}")

if ! declare -f "exec_rollout_status" > /dev/null; then
  echo -e "${RED}❌ Error: exec_rollout_status function is not defined in subshell${NC}" >&2
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "${ARGO_CLI_COMMON_SCRIPT}")

if ! declare -f "with_argocd_cli" > /dev/null; then
  echo -e "${RED}❌ Error: with_argocd_cli function is not defined in subshell${NC}" >&2
  exit 2
fi

exec_rollout_status \
  --rollout-name "${ROLLOUT_NAME}" \
  --namespace "${NAMESPACE}" \
  --timeout "${ROLLOUT_STATUS_TIMEOUT}" \
  --interval "${ROLLOUT_STATUS_CHECK_INTERVAL}"

exit $?
