#!/bin/bash

# Script to check the status of an Argo Rollout.
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

# Main entrypoint
function exec_rollout_status() {

  # Export variables so they are available in the environment of the subshell
  # executed by 'timeout'. This is necessary because 'timeout' runs the command
  # in a new bash process, and only exported variables are accessible there.
  export rollout_name="${ROLLOUT_NAME}"
  export namespace="${NAMESPACE}"
  export rollout_status_timeout="${ROLLOUT_STATUS_TIMEOUT:-1m}"
  export rollout_status_check_interval="${ROLLOUT_STATUS_CHECK_INTERVAL:-10}"

  # Check required variables
  if [[ -z "$rollout_name" ]] || [[ -z "$namespace" ]]; then
    echo "Error: Missing required environment variables to check rollout status."
    echo "Please set the following environment variables:"
    echo "     ROLLOUT_NAME - The rollout name to check"
    echo "     NAMESPACE - The namespace to check"
    echo "     ROLLOUT_STATUS_TIMEOUT - Timeout in seconds (default: 1m)"
    echo "     ROLLOUT_STATUS_CHECK_INTERVAL - Interval between checks in seconds (default: 10)"
    exit 2
  fi

  # Print result
  function print_rollout_status_result() {
    local status="$1"
    local message="$2"
    echo "--------------------------------------------------------"
    echo "📊 Result: ${message}"
    echo "   - Status: ${status}"
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

  timeout "${rollout_status_timeout}" bash -o pipefail -c "$(declare -f check_rollout_status print_rollout_status_result); check_rollout_status"
  timeout_result=$?
  if [[ $timeout_result -eq 124 ]]; then
    echo "⏰ Timeout reached while checking rollout status."
    exit 0
  else
    exit $timeout_result
  fi
}
