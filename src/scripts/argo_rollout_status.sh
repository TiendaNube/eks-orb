#!/bin/bash

# Script to check the status of an Argo Rollout release
#
# Usage: Set the following environment variables:
#   ROLLOUT_NAME                  - The rollout name to check
#   NAMESPACE                     - The namespace to check
#   ROLLOUT_STATUS_TIMEOUT        - Timeout in seconds
#   ROLLOUT_STATUS_CHECK_INTERVAL - Interval between checks in seconds
#
# Returns:
#   - Exit code 0 if rollout is Healthy or Completed, or if timeout is reached
#   - Exit code 1 if rollout is Degraded, Error, or Aborted
#   - Exit code 2 for script errors
if [[ -z "${ROLLOUT_STATUS_COMMON_SCRIPT:-}" ]]; then
  echo "Error: COMMON_SCRIPT is empty" >&2
  exit 2
fi

source <(echo "$ROLLOUT_STATUS_COMMON_SCRIPT")

exec_rollout_status \
  --rollout-name "${ROLLOUT_NAME}" \
  --namespace "${NAMESPACE}" \
  --timeout "${ROLLOUT_STATUS_TIMEOUT}" \
  --interval "${ROLLOUT_STATUS_CHECK_INTERVAL}"

exit $?
