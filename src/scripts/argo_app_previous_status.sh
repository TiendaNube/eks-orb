#!/bin/bash

# Script to check the status of an Argo Application
# It expects ARGO_CLI_COMMON_SCRIPT to be set and sources it for required functions.
#
# Usage: Set the following environment variables:
#   RELEASE_NAME                           - The release name to check
#   ARGO_APP_STATUS_TIMEOUT                - Timeout in seconds
#   ARGO_APP_STATUS_CHECK_INTERVAL         - Interval between checks in seconds
#   ARGO_APP_STATUS_SYNC_STATUS_THRESHOLD  - Number of times that the result status is Sync before moving forward with the rollout
#   ARGO_APP_STATUS_DEBUG                  - Whether to print debug information (use string to avoid boolean type conversion issues)
#   ARGO_CLI_COMMON_SCRIPT                 - The script to source for required functions
#
# Returns:
#   - Exit code 0 if application Rollout can proceed: Health or Degraded, Sync or OutOfSync.
#   - Exit code 1 if application Rollout should be blocked: remains Suspended or Syncing until timeout.
#   - Exit code 2 for script errors

# Colors for output
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

ARGOCD_DOCS_URL="https://tiendanube.atlassian.net/wiki/spaces/EP/pages/494403591/Using+ArgoCD+for+Progressive+Delivery"

function print_header() {
  echo "========================================================"
  echo "🔍 Checking Argo Application Health and Sync status for:"
  echo "   - Release: ${RELEASE_NAME}"
  echo "   - Namespace: ${APPLICATION_NAMESPACE}"
  echo "   - Timeout: ${ARGO_APP_STATUS_TIMEOUT}"
  echo "   - Check interval: ${ARGO_APP_STATUS_CHECK_INTERVAL} (seconds)"
  echo "   - Sync status threshold: ${ARGO_APP_STATUS_SYNC_STATUS_THRESHOLD}"
  echo "   - Debug: ${ARGO_APP_STATUS_DEBUG}"
  echo "========================================================"
}

# shellcheck disable=SC2329
function print_debug_output() {
  local output="$1"
  if [[ $ARGO_APP_STATUS_DEBUG == "true" ]]; then
    echo "---- CMD OUTPUT --------------------------------------------"
    echo "$output"
    echo "------------------------------------------------------------"
  fi
}

# shellcheck disable=SC2329
function print_rollout_blocked_tip() {
  local sync_status="$1"
  local health_status="$2"
  local operation_phase="$3"

  echo -e "${YELLOW}⚠️ ArgoCD Application Health: ${health_status}; Sync status: ${sync_status}; Operation Phase: ${operation_phase}; waiting...${NC}"
  echo -e "************************************************************************************"
  echo -e "${YELLOW}💡 Tip:${NC}"
  echo -e "${YELLOW}You can visit the ArgoCD UI to help resolve the conflict status if needed.${NC}"
  if [[ "$health_status" == "Suspended" ]]; then
    echo -e "${YELLOW}Use the 'Abort', 'Resume' or 'Promote-Full' operations to unlock Suspended status.${NC}"
  else
    echo -e "${YELLOW}If the operation is blocked, evaluate using the 'Terminate' operation (at your own risk).${NC}"
  fi
  echo -e "${BLUE}🔗 Using ArgoCD for Progressive Delivery: ${ARGOCD_DOCS_URL}${NC}"
  echo -e "************************************************************************************"
}

#shellcheck disable=SC2329
function check_argocd_app_status() {
  local output json_output sync_status health_status operation_phase
  local i=1 synced_status_count=0

  while true; do
    echo "========================================================"
    echo "🔍 Checking Argo Application status (attempt $i)..."

    output=$(with_argocd_cli --namespace "${APPLICATION_NAMESPACE}" -- argocd app get "${RELEASE_NAME}" --output json)
    print_debug_output "$output"

    # Extract JSON part by finding the first '{' and last '}' to get only valid JSON
    json_output=$(echo "$output" | awk '/^{/ {flag=1} flag && /^}$/ {print; exit} flag')
    
    sync_status=$(echo "$json_output" | jq -r '.status.sync.status // "Unknown"')
    health_status=$(echo "$json_output" | jq -r '.status.health.status // "Unknown"')
    operation_phase=$(echo "$json_output" | jq -r '.status.operationState.phase // "Unknown"')
    if [[ $health_status == "Suspended" ]]; then
      synced_status_count=0
      print_rollout_blocked_tip "$sync_status" "$health_status" "$operation_phase"
    elif [[ $operation_phase == "Running" ]]; then
      synced_status_count=0
      print_rollout_blocked_tip "$sync_status" "$health_status" "$operation_phase"
    else
      if [[ $sync_status == "Synced" ]]; then
        synced_status_count=$((synced_status_count+1))
        echo -e "${GREEN}✅ ArgoCD Application is 'Synced'; Health: ${health_status}; Operation Phase: ${operation_phase}${NC}"
        if [[ "$synced_status_count" -ge "$ARGO_APP_STATUS_SYNC_STATUS_THRESHOLD" ]]; then
          print_debug_output "$output"
          echo -e "${GREEN}🚀 After ${synced_status_count} successful attempts, DONE.${NC}"
          exit 0
        else
          echo -e "${GREEN}⏳ Waiting for consecutive 'Synced' status...${NC}"
        fi
      else
        echo -e "${YELLOW}⚠️ ArgoCD Application is 'OutOfSync'; Health: ${health_status}; Operation Phase: ${operation_phase}${NC}"
        echo -e "${YELLOW}🚀 Proceeding with the rollout in order to synchronize the application.${NC}"
        exit 0
      fi
    fi

    echo "========================================================"
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

if ! [[ "$ARGO_APP_STATUS_CHECK_INTERVAL" =~ ^[0-9]+$ && "$ARGO_APP_STATUS_SYNC_STATUS_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ Error: CHECK_INTERVAL and SYNC_STATUS_THRESHOLD must be integers (seconds/count).${NC}"
  exit 2
fi

if [[ -z "$ARGO_APP_STATUS_DEBUG" ]]; then
  ARGO_APP_STATUS_DEBUG=false
fi

# Validate that ArgoCD CLI is available
if ! command -v argocd >/dev/null 2>&1; then
  echo -e "${RED}❌ Error: argocd CLI is not installed or not in PATH.${NC}"
  exit 2
fi

# Validate that jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}❌ Error: jq is not installed or not in PATH.${NC}"
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

export GREEN BLUE YELLOW RED NC
export ARGOCD_DOCS_URL
export RELEASE_NAME APPLICATION_NAMESPACE
export ARGO_APP_STATUS_CHECK_INTERVAL ARGO_APP_STATUS_SYNC_STATUS_THRESHOLD ARGO_APP_STATUS_DEBUG ARGO_CLI_COMMON_SCRIPT

timeout "${ARGO_APP_STATUS_TIMEOUT}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f check_argocd_app_status print_rollout_blocked_tip print_debug_output with_argocd_cli set_argocd_cli unset_argocd_cli)
  check_argocd_app_status
EOF
)" || TIMEOUT_RESULT=$?

if [[ $TIMEOUT_RESULT -eq 124 ]]; then
  echo "⏰ Timeout reached while checking application status."
  exit 1
else
  exit $TIMEOUT_RESULT
fi
