#!/bin/bash

# Script to check the status of an Argo Application
#
# Usage: Set the following environment variables:
#   RELEASE_NAME                   - The release name to check
#   ARGO_APP_STATUS_TIMEOUT        - Timeout in seconds
#   ARGO_APP_STATUS_CHECK_INTERVAL - Interval between checks in seconds
#   ARGO_APP_STATUS_DEBUG          - Whether to print debug information
#
# Returns:
#   - Exit code 0 if application is Synced (in any state: Healthy, Completed, Degraded, Error, or Aborted).
#   - Exit code 1 if application is OutOfSync (Suspended or Progressing) and timeout is reached.
#   - Exit code 2 for script errors

# Print status header
function print_header() {
  echo "========================================================"
  echo "🔍 Checking Argo Application Health and Sync status for:"
  echo "   - Release: ${RELEASE_NAME}"
  echo "   - Timeout: ${ARGO_APP_STATUS_TIMEOUT}"
  echo "   - Check interval: ${ARGO_APP_STATUS_CHECK_INTERVAL}s"
  echo "   - Debug: ${ARGO_APP_STATUS_DEBUG}"
  echo "--------------------------------------------------------"
}

#shellcheck disable=SC2329
function check_argocd_app_status() {
  local output
  local i=1

  while true; do
    echo "========================================================"
    echo "🔍 Checking Argo Application status (attempt $i)..."
    output=$(argocd app get "argocd/${RELEASE_NAME}")
    if [[ $ARGO_APP_STATUS_DEBUG == true ]]; then
      echo "$output"
    fi
    if echo "$output" | grep "Sync Status:.*OutOfSync" >/dev/null 2>&1; then
      echo "ArgoCD Application is out of sync"
      if echo "$output" | grep "Health Status:.*Suspended" >/dev/null 2>&1; then
        echo "ArgoCD Application is suspended"
      elif echo "$output" | grep "Health Status:.*Progressing" >/dev/null 2>&1; then
        echo "ArgoCD Application is progressing"
      fi
    else
      echo "ArgoCD Application is in valid state for deployment"
      echo "$output"
      exit 0
    fi
    i=$((i+1))
    sleep "${ARGO_APP_STATUS_CHECK_INTERVAL}"
  done
}

set +e

if [[ -z "$RELEASE_NAME" ]] || [[ -z "$ARGO_APP_STATUS_TIMEOUT" ]] || [[ -z "$ARGO_APP_STATUS_CHECK_INTERVAL" ]]; then
  echo "Error: RELEASE_NAME, ARGO_APP_STATUS_TIMEOUT, and ARGO_APP_STATUS_CHECK_INTERVAL are required."
  exit 2
fi

if [[ -z "$ARGO_APP_STATUS_DEBUG" ]]; then
  ARGO_APP_STATUS_DEBUG=false
fi

print_header

TIMEOUT_RESULT=0

export RELEASE_NAME ARGO_APP_STATUS_CHECK_INTERVAL ARGO_APP_STATUS_DEBUG

timeout "${ARGO_APP_STATUS_TIMEOUT}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f check_argocd_app_status)
  check_argocd_app_status
EOF
)" || TIMEOUT_RESULT=$?

if [[ $TIMEOUT_RESULT -eq 124 ]]; then
  echo "⏰ Timeout reached while checking application status."
  exit 1
else
  exit $TIMEOUT_RESULT
fi
