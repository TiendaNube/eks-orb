#!/bin/bash

# Script to check the status of an Argo Rollout release
#
# Usage: Set the following environment variables:
#   ROLLOUT_NAME   - The rollout name to check
#   NAMESPACE      - The namespace to check
#   ROLLOUT_STATUS_TIMEOUT        - Timeout in seconds (default: 1m)
#   ROLLOUT_STATUS_CHECK_INTERVAL - Interval between checks in seconds (default: 10)
#
# Returns:
#   - Exit code 0 if rollout is Healthy or Completed, or if timeout is reached
#   - Exit code 1 if rollout is Degraded, Error, or Aborted
#   - Exit code 2 for script errors
if [[ -z "${COMMON_SCRIPT:-}" ]]; then
  echo "Error: COMMON_SCRIPT is empty" >&2
  exit 2
fi

source <(echo "$COMMON_SCRIPT")

exec_rollout_status
exit $?
