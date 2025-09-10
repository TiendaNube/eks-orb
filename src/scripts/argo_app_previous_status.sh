#!/bin/bash

# Script to check the status of an Argo Application
# It expects ARGO_CLI_COMMON_SCRIPT to be set and sources it for required functions.
#
# Usage: Set the following environment variables:
#   RELEASE_NAME                   - The release name to check
#   ARGO_APP_STATUS_TIMEOUT        - Timeout in seconds
#   ARGO_APP_STATUS_CHECK_INTERVAL - Interval between checks in seconds
#   ARGO_APP_STATUS_DEBUG          - Whether to print debug information
#   ARGO_CLI_COMMON_SCRIPT        - The script to source for required functions
#
# Returns:
#   - Exit code 0 if application Sync Status is Synced (regardless of Health).
#   - Exit code 1 if application remains OutOfSync until timeout.
#   - Exit code 2 for script errors

# Colors for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m" # No Color

function print_header() {
  echo "========================================================"
  echo "🔍 Checking Argo Application Health and Sync status for:"
  echo "   - Release: ${RELEASE_NAME}"
  echo "   - Timeout: ${ARGO_APP_STATUS_TIMEOUT}"
  echo "   - Check interval: ${ARGO_APP_STATUS_CHECK_INTERVAL}s"
  echo "   - Debug: ${ARGO_APP_STATUS_DEBUG}"
  echo "========================================================"
}

#shellcheck disable=SC2329
function check_argocd_app_status() {
  local output sync_status health_status
  local i=1

  while true; do
    echo "========================================================"
    echo "🔍 Checking Argo Application status (attempt $i)..."

    output=$(with_argocd_cli --namespace "${APPLICATION_NAMESPACE}" -- argocd app get "${RELEASE_NAME}" --output json)
    if [[ $ARGO_APP_STATUS_DEBUG ]]; then
      echo "---- CMD OUTPUT --------------------------------------------"
      echo "$output"
      echo "------------------------------------------------------------"
    fi

    # Extract JSON part by finding the first '{' and last '}' to get only valid JSON
    json_output=$(echo "$output" | awk '/^{/ {flag=1} flag && /^}$/ {print; exit} flag')
    
    sync_status=$(echo "$json_output" | jq -r '.status.sync.status // "Unknown"')
    health_status=$(echo "$json_output" | jq -r '.status.health.status // "Unknown"')
    if [[ "$sync_status" == "OutOfSync" ]]; then
      echo -e "${YELLOW}⚠️ ArgoCD Application is OutOfSync with health status: ${health_status}${NC}"
    else
      echo -e "${GREEN}✅ ArgoCD Application is in valid state for deployment with health status: ${health_status}${NC}"
      echo "$output"
      exit 0
    fi

    i=$((i+1))
    sleep "${ARGO_APP_STATUS_CHECK_INTERVAL}"
  done
}

set +e

if [[ -z "$RELEASE_NAME" ]] || [[ -z "$ARGO_APP_STATUS_TIMEOUT" ]] || 
   [[ -z "$ARGO_APP_STATUS_CHECK_INTERVAL" ]] || [[ -z "$ARGO_CLI_COMMON_SCRIPT" ]]; then
  echo -e "${RED}❌ Error: RELEASE_NAME, ARGO_APP_STATUS_TIMEOUT, ARGO_APP_STATUS_CHECK_INTERVAL, and ARGO_CLI_COMMON_SCRIPT are required.${NC}"
  exit 2
fi

if [[ -z "$ARGO_APP_STATUS_DEBUG" ]]; then
  ARGO_APP_STATUS_DEBUG=false
fi

# Validate that argocd CLI is available
if ! command -v argocd >/dev/null 2>&1; then
  echo -e "${RED}❌ Error: argocd CLI is not installed or not in PATH.${NC}"
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "$ARGO_CLI_COMMON_SCRIPT")

# Check that the with_argocd_cli function is available
if ! declare -f with_argocd_cli > /dev/null; then
  echo -e "${RED}❌ with_argocd_cli function is not defined in subshell!${NC}"
  exit 2
fi

print_header

TIMEOUT_RESULT=0

export RELEASE_NAME ARGO_APP_STATUS_CHECK_INTERVAL ARGO_APP_STATUS_DEBUG ARGO_CLI_COMMON_SCRIPT

timeout "${ARGO_APP_STATUS_TIMEOUT}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f check_argocd_app_status with_argocd_cli set_argocd_cli unset_argocd_cli)
  check_argocd_app_status
EOF
)" || TIMEOUT_RESULT=$?

if [[ $TIMEOUT_RESULT -eq 124 ]]; then
  echo "⏰ Timeout reached while checking application status."
  exit 1
else
  exit $TIMEOUT_RESULT
fi
