#!/bin/bash

# Script to check the status of an Argo Rollout.
#
# Usage:
#   ./argo_rollout_status_common.sh --rollout-name <name> --namespace <ns> --timeout <1m> --interval <10>
#
# Returns:
#   - Exit code 0 if rollout is Healthy or Completed, or if timeout is reached
#   - Exit code 1 if rollout is Degraded, Error, or Aborted
#   - Exit code 2 for script errors

# Colors for output
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Main entrypoint
function exec_rollout_status() {

  local rollout_name="" namespace="" rollout_status_timeout="" rollout_status_check_interval=""

  # Parse flags
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --rollout-name) rollout_name="$2"; shift 2 ;;
      --namespace) namespace="$2"; shift 2 ;;
      --timeout) rollout_status_timeout="$2"; shift 2 ;;
      --interval) rollout_status_check_interval="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo -e "${RED}Unknown flag: $1${NC}"; return 2 ;;
    esac
  done

  # Check required flags
  if [[ -z "$rollout_name" ]] || [[ -z "$namespace" ]] || [[ -z "$rollout_status_timeout" ]] || [[ -z "$rollout_status_check_interval" ]]; then
    echo -e "${RED}Error: --rollout-name, --namespace, --timeout, and --interval are required.${NC}"
    echo -e "Usage: $0 --rollout-name <name> --namespace <ns> --timeout <1m> --interval <10>"
    return 2
  fi

  # Print result
  #shellcheck disable=SC2329
  function print_rollout_status_result() {
    local status="$1"
    local message="$2"
    local color="${RED}"

    if [[ "$status" =~ ^(Healthy|Completed)$ ]]; then
      color="${GREEN}"
    fi
    echo -e "${color}--------------------------------------------------------"
    echo -e "📊 Result: ${message}"
    echo -e "   - Status: ${status}${NC}"
  }

  #shellcheck disable=SC2329
  function rollout_is_auto_sync_disabled() {
    local sync_status="$1"
    local auto_sync_status="$2"
    local auto_sync_self_heal="$3"
    local auto_sync_prune="$4"

    # If at least one of the `syncPolicy.automated.[enabled|selfHeal|prune]` fields is disabled, this function returns true.
    # $auto_sync_status == "false" is currently not used because it's not consistent throughout every ArgoCD Application JSON response.
    { 
      [[ $sync_status == "OutOfSync" ]] &&
      [[ $auto_sync_self_heal == "false" || $auto_sync_prune == "false" ]]
    }
  }

  #shellcheck disable=SC2329
  function rollout_is_progressing() {
    local rollout_status="$1"
    local sync_status="$2"
    local health_status="$3"
    local operation_phase="$4"

    {
      [[ $rollout_status =~ ^(Progressing|Paused)$ ]] ||
      [[ $operation_phase == "Running" ]] ||
      [[ $health_status =~ ^(Progressing|Suspended|Missing)$ ]]
    }
  }

  # Main status check loop
  #shellcheck disable=SC2329
  function check_rollout_status() {
    local kubectl_output argocd_output rollout_status sync_status health_status operation_phase auto_sync_status
    local i=1

    while true; do
      echo "============================================================="
      echo "🔍 Checking Rollout / Application status (attempt $i)..."
      # Get kubectl rollout status
      kubectl_output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}")
      echo "$kubectl_output"
      rollout_status=$(echo "$kubectl_output" | grep "^Status:" | awk '{print $3}')

      # Get application status
      argocd_output=$(with_argocd_cli --namespace "${APPLICATION_NAMESPACE}" -- argocd app get "${rollout_name}" --output json)
      operation_phase=$(echo "$argocd_output" | jq -r '.status.operationState.phase // "None"')
      sync_status=$(echo "$argocd_output" | jq -r '.status.sync.status // "Unknown"')
      health_status=$(echo "$argocd_output" | jq -r '.status.health.status // "Unknown"')
      auto_sync_status=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.enabled // "false"')
      auto_sync_self_heal=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.selfHeal // "false"')
      auto_sync_prune=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.prune // "false"')

      if rollout_is_progressing "$rollout_status" "$sync_status" "$health_status" "$operation_phase"; then
        echo -e "${BLUE}⏳ Waiting... Rollout status is [$rollout_status].${NC}"
        echo -e "${BLUE}Application Sync status [$sync_status]; Health status [$health_status]; Operation phase [$operation_phase].${NC}"
      elif rollout_is_auto_sync_disabled "$sync_status" "$auto_sync_status" "$auto_sync_self_heal" "$auto_sync_prune"; then
        echo "**********************************************************************"
        echo "$argocd_output" | jq -r '.spec.syncPolicy'
        echo "**********************************************************************"
        echo -e "${YELLOW}--------------------------------------------------------"
        echo -e "${YELLOW}⚠️ WARNING: Auto sync is disabled${NC}"
        echo -e "${YELLOW}You must visit the ArgoCD UI to enable this feature in order to apply the already launched rollout.${NC}"
        echo -e "${YELLOW}Pay special attention to activating these TWO fields:${NC}"
        echo -e "${YELLOW} - Prune${NC}"
        echo -e "${YELLOW} - Self Heal${NC}"
        echo -e "${YELLOW}--------------------------------------------------------${NC}"
      else
        case "$rollout_status" in
          Healthy|Completed)
            print_rollout_status_result "$rollout_status" "✅ Rollout is $rollout_status."
            return 0
            ;;
          Degraded|Error|Aborted)
            print_rollout_status_result "$rollout_status" "❌ Rollout status is $rollout_status. Exiting with failure."
            return 1
            ;;
          *)
            echo -e "${YELLOW}❓ Unknown status: [$rollout_status]. Waiting...${NC}"
            echo -e "${YELLOW}Application Sync status [$sync_status]; Health status [$health_status]; Operation phase [$operation_phase].${NC}"
            ;;
        esac
      fi

      i=$((i+1))
      sleep "${rollout_status_check_interval}"
    done
  }

  # Print status header
  function print_header() {
    echo "========================================================"
    echo "🔍 Checking Argo Rollout status for:"
    echo "   - Rollout: ${rollout_name}"
    echo "   - Namespace: ${namespace}"
    echo "   - Timeout: ${rollout_status_timeout}"
    echo "   - Check interval: ${rollout_status_check_interval}s"
    echo "--------------------------------------------------------"
  }

  set +e
  
  print_header

  # Export variables needed by the subshell invoked by timeout.
  export rollout_name namespace rollout_status_timeout rollout_status_check_interval
  export GREEN BLUE YELLOW RED NC

  local timeout_result=0
  timeout "${rollout_status_timeout}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f print_rollout_status_result rollout_is_progressing rollout_is_auto_sync_disabled)
  $(declare -f with_argocd_cli set_argocd_cli unset_argocd_cli is_argocd_logged_in is_kubectl_namespace_set)
  $(declare -f check_rollout_status)
  check_rollout_status
EOF
)" || timeout_result=$?

  if [[ $timeout_result -eq 124 ]]; then
    echo "⏰ Timeout reached while checking rollout status."
    return 0
  else
    return $timeout_result
  fi
}
