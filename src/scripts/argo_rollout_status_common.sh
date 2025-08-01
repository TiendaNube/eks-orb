#!/bin/bash

# Colors for output
RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m" # No Color

# Script to check the status of an Argo Rollout.
#
# Usage:
#   ./argo_rollout_status_common.sh --rollout-name <name> --namespace <ns> --timeout <1m> --interval <10>
#
# Returns:
#   - Exit code 0 if rollout is Healthy or Completed, or if timeout is reached
#   - Exit code 1 if rollout is Degraded, Error, or Aborted
#   - Exit code 2 for script errors

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
  function print_rollout_status_result() {
    local status="$1"
    local message="$2"
    local color="${RED}"
    if [[ "$status" == "Healthy" || "$status" == "Completed" ]]; then
      color="${GREEN}"
    fi
    echo -e "${color}--------------------------------------------------------"
    echo -e "📊 Result: ${message}"
    echo -e "   - Status: ${status}${NC}"
  }

  # Main status check loop
  function check_rollout_status() {
    local i=1
    while true; do
      echo "========================================================"
      echo "🔍 Checking Rollout status (attempt $i)..."
      output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}")
      echo "$output"
      status=$(echo "$output" | grep "^Status:" | awk '{print $3}')
      case "$status" in
        Healthy|Completed)
          print_rollout_status_result "$status" "✅ Rollout is $status."
          return 0
          ;;
        Degraded|Error|Aborted)
          print_rollout_status_result "$status" "❌ Rollout status is $status. Exiting with failure."
          return 1
          ;;
        Progressing|Paused)
          echo "⏳ Rollout status is $status. Waiting..."
          ;;
        *)
          echo "❓ Unknown status: $status. Waiting..."
          ;;
      esac
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

  local timeout_result=0
  timeout "${rollout_status_timeout}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f check_rollout_status print_rollout_status_result)
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
