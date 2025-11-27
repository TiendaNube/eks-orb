#!/bin/bash

# Script to check the status of an Argo Rollout.
#
# Usage:
#   ./argo_rollout_status_common.sh --rollout-name <name> --namespace <ns> --timeout <1m> --interval <10>
#
#   Set the following environment variables:
#   - ARGO_CLI_COMMON_SCRIPT           - The script to source for reusable Argo CLI functions
#   - UPDATE_KUBECONFIG_COMMON_SCRIPT  - The script to source for reusable kubeconfig functions
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

if [[ -z "${ARGO_CLI_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: ARGO_CLI_COMMON_SCRIPT is empty${NC}" >&2
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "${ARGO_CLI_COMMON_SCRIPT}")

if ! declare -f "with_argocd_cli" > /dev/null; then
  echo -e "${RED}❌ Error: with_argocd_cli function is not defined.${NC}" >&2
  exit 2
fi

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

# Main entrypoint
function exec_rollout_status() {
  local rollout_name="" namespace="" rollout_status_timeout="" rollout_status_check_interval="" project_repo_name=""

  if [[ -z "${APPLICATION_NAMESPACE}" ]]; then
    echo -e "${RED}❌ Error: APPLICATION_NAMESPACE environment variable is required.${NC}"
    return 2
  fi

  # Parse flags
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --rollout-name) rollout_name="$2"; shift 2 ;;
      --namespace) namespace="$2"; shift 2 ;;
      --project-repo-name) project_repo_name="$2"; shift 2 ;;
      --timeout) rollout_status_timeout="$2"; shift 2 ;;
      --interval) rollout_status_check_interval="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo -e "${RED}Unknown flag: $1${NC}"; return 2 ;;
    esac
  done

  # Check required flags
  if [[ -z "$rollout_name" ]] || [[ -z "$namespace" ]] || [[ -z "$project_repo_name" ]] ||
     [[ -z "$rollout_status_timeout" ]] || [[ -z "$rollout_status_check_interval" ]]; then
    echo -e "${RED}Error: --rollout-name, --namespace, --project-repo-name, --timeout, and --interval are required.${NC}"
    echo -e "Usage: $0 --rollout-name <name> --namespace <ns> --project-repo-name <repo> --timeout <1m> --interval <10>"
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
  function get_auto_sync_enabled() {
    local argocd_output="$1"
    local enabled_exists enabled_value auto_sync_prune auto_sync_self_heal

    # Check if automated.enabled field exists and is not null
    enabled_exists=$(echo "$argocd_output" | jq -r 'if .spec.syncPolicy.automated.enabled != null then "true" else "false" end')

    # If enabled field exists and is not null, use that value
    if [[ "$enabled_exists" == "true" ]]; then
      enabled_value=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.enabled')
      echo "$enabled_value"
      return
    fi

    auto_sync_prune=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.prune // "false"')
    auto_sync_self_heal=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.selfHeal // "false"')
    # If enabled is not present, check if both prune and selfHeal are true
    if [[ "$auto_sync_prune" == "true" ]] && [[ "$auto_sync_self_heal" == "true" ]]; then
      echo "true"
      return
    fi

    # Any other case returns false
    echo "false"
  }

  #shellcheck disable=SC2329
  function rollout_is_auto_sync_disabled() {
    local auto_sync_status="$1"
    local auto_sync_self_heal="$2"
    local auto_sync_prune="$3"

    # If at least one of the `syncPolicy.automated.[enabled|selfHeal|prune]` fields is disabled, this function returns true.
    {
      [[ $auto_sync_status == "false" ]] || [[ $auto_sync_self_heal == "false" ]] || [[ $auto_sync_prune == "false" ]]
    }
  }

  #shellcheck disable=SC2329
  function rollout_is_progressing() {
    local rollout_status="$1"
    local health_status="$2"
    local operation_phase="$3"

    {
      [[ $rollout_status =~ ^(Progressing|Paused)$ ]] ||
      [[ $operation_phase == "Running" ]] ||
      [[ $health_status =~ ^(Progressing|Suspended|Missing)$ ]]
    }
  }

  #shellcheck disable=SC2329
  function is_not_found_error() {
    local error_output="$1"
    # Check for "not found" error patterns
    {
      [[ "$error_output" =~ [Nn]ot.*[Ff]ound ]] ||
      [[ "$error_output" =~ [Ee]rror.*rollout.*not.*found ]] ||
      [[ "$error_output" =~ rollout\.argoproj\.io.*not.*found ]]
    }
  }

  #shellcheck disable=SC2329
  function check_kubectl_auth() {
    local namespace="$1"
    
    # Test authentication with a lightweight command
    if kubectl auth can-i get pods --namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    else
      return 1
    fi
  }

  #shellcheck disable=SC2329
  function refresh_kubeconfig() {
    echo -e "${BLUE}🔄 Attempting to refresh kubeconfig...${NC}"

    if update_kubeconfig; then
      echo -e "${GREEN}✅ Kubeconfig refreshed successfully${NC}"
      return 0
    else
      echo -e "${RED}❌ Failed to refresh kubeconfig${NC}" >&2
      return 1
    fi
  }

  #shellcheck disable=SC2329
  function get_kubectl_argo_rollout() {
    local rollout_name="$1"
    local namespace="$2"
    local kubectl_output kubectl_exit_code=0
    local max_retries=3
    local attempt=1

    while [[ $attempt -le $max_retries ]]; do
      kubectl_output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}" 2>&1) || kubectl_exit_code=$?

      if [[ $kubectl_exit_code -eq 0 ]] || is_not_found_error "$kubectl_output"; then
        echo "$kubectl_output"
        return 0
      fi

      # Check for authentication errors and retry with token refresh
      if ! check_kubectl_auth "$namespace" >/dev/null 2>&1; then
        # Check if we have retries left (the loop condition handles the limit, but we check here
        # to avoid unnecessary kubeconfig refresh on the last attempt)
        if [[ $attempt -lt $max_retries ]]; then
          echo -e "${BLUE}🔄 Authentication error detected (attempt $attempt/$max_retries). Refreshing kubeconfig...${NC}"
          if refresh_kubeconfig; then
            attempt=$((attempt + 1))
            echo -e "${BLUE}🔄 Retrying kubectl command after kubeconfig refresh...${NC}"
            continue
          else
            echo -e "${RED}❌ Failed to refresh kubeconfig. Cannot continue.${NC}" >&2
            return 2
          fi
        fi
        # If we've exhausted all retries, return error
        echo -e "${RED}❌ kubectl command failed after $max_retries attempts:${NC}" >&2
        echo "$kubectl_output" >&2
        return 2
      else
        # Any other error (not "not found" and not auth error) should fail
        echo -e "${RED}❌ kubectl command failed (unexpected error):${NC}" >&2
        echo "$kubectl_output" >&2
        return 2
      fi
    done

    # Should not reach here, but just in case
    echo -e "${RED}❌ kubectl command failed after $max_retries attempts${NC}" >&2
    return 2
  }

  # Main status check loop
  #shellcheck disable=SC2329
  function check_rollout_status() {
    local kubectl_output argocd_output rollout_status sync_status health_status operation_phase auto_sync_status
    local i=1

    local kubectl_exit_code=0

    while true; do
      echo "-------------------------------- DEBUG AWS EXPIRATION -------"
      aws_credentials=$(aws configure export-credentials --format env-no-export 2>/dev/null)
      echo "$aws_credentials" | grep EXPIRATION
      # Mask AWS_ACCESS_KEY_ID to show only last 4 characters
      access_key_line=$(echo "$aws_credentials" | grep AWS_ACCESS_KEY_ID)
      if [[ -n "$access_key_line" ]]; then
        access_key_value="${access_key_line#*=}"
        access_key_last4="${access_key_value: -4}"
        echo "AWS_ACCESS_KEY_ID=****${access_key_last4}"
      fi
      # Mask AWS_SECRET_ACCESS_KEY to show only last 4 characters
      secret_key_line=$(echo "$aws_credentials" | grep AWS_SECRET_ACCESS_KEY)
      if [[ -n "$secret_key_line" ]]; then
        secret_key_value="${secret_key_line#*=}"
        secret_key_last4="${secret_key_value: -4}"
        echo "AWS_SECRET_ACCESS_KEY=****${secret_key_last4}"
      fi
      echo "-------------------------------------------------------------"
      echo "============================================================="
      echo "🔍 Checking Rollout / Application status (attempt $i)..."
      # Get kubectl rollout status (handles errors and retries internally)
      # kubectl_output=$(get_kubectl_argo_rollout "${rollout_name}" "${namespace}") || return $?

      echo "Checking kubectl auth"
      kubectl auth can-i get pods --namespace "${namespace}"

      echo "Getting kubectl rollout status"
      kubectl_output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}" 2>&1) || kubectl_exit_code=$?

      echo "kubectl_exit_code: $kubectl_exit_code"

      if [[ $kubectl_exit_code -ne 0 ]] && ! is_not_found_error "$kubectl_output"; then
        echo "kubectl command failed"
        # Check for authentication errors and retry with token refresh
        if ! check_kubectl_auth "$namespace" >/dev/null 2>&1; then
          echo -e "${BLUE}🔄 Authentication error detected. Refreshing kubeconfig...${NC}"
          if refresh_kubeconfig; then
            echo -e "${BLUE}🔄 Retrying kubectl command after kubeconfig refresh...${NC}"
            kubectl_output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}" 2>&1) 
          else
            echo -e "${RED}❌ Failed to refresh kubeconfig. Cannot continue.${NC}" >&2
            exit 2
          fi
        else
          # Any other error (not "not found" and not auth error) should fail
          echo -e "${RED}❌ kubectl command failed (unexpected error):${NC}" >&2
          echo "$kubectl_output" >&2
          exit 2
        fi
      else
        echo "kubectl command succeeded"
      fi
      echo "kubectl_output:"
      echo "$kubectl_output"

      rollout_status=$(echo "$kubectl_output" | grep "^Status:" | awk '{print $3}')

      # Get application status
      argocd_output=$(with_argocd_cli --namespace "${APPLICATION_NAMESPACE}" -- argocd app get "${rollout_name}" --output json)
      operation_phase=$(echo "$argocd_output" | jq -r '.status.operationState.phase // "None"')
      sync_status=$(echo "$argocd_output" | jq -r '.status.sync.status // "Unknown"')
      health_status=$(echo "$argocd_output" | jq -r '.status.health.status // "Unknown"')
      auto_sync_status=$(get_auto_sync_enabled "$argocd_output")
      auto_sync_prune=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.prune // "false"')
      auto_sync_self_heal=$(echo "$argocd_output" | jq -r '.spec.syncPolicy.automated.selfHeal // "false"')

      if rollout_is_progressing "$rollout_status" "$health_status" "$operation_phase"; then
        echo -e "${BLUE}⏳ Waiting... Rollout status is [$rollout_status].${NC}"
        echo -e "${BLUE}Application Sync status [$sync_status]; Health status [$health_status]; Operation phase [$operation_phase].${NC}"
      elif rollout_is_auto_sync_disabled "$auto_sync_status" "$auto_sync_self_heal" "$auto_sync_prune"; then
        echo "**********************************************************************"
        echo "$argocd_output" | jq -r '.spec.syncPolicy'
        echo "**********************************************************************"
        echo -e "${YELLOW}--------------------------------------------------------"
        echo -e "${YELLOW}⚠️ Auto sync is disabled. Enabling it manually...${NC}"
        echo -e "${YELLOW}--------------------------------------------------------${NC}"

        # Enable auto sync with prune and self-heal
        if with_argocd_cli --namespace "${APPLICATION_NAMESPACE}" -- \
          argocd app set "${rollout_name}" --source-name "${project_repo_name}" --sync-policy automated --auto-prune --self-heal; then
          echo -e "${GREEN}✅ Successfully enabled auto sync with prune and self-heal${NC}"
          echo -e "${BLUE}⏳ Waiting for sync to start...${NC}"
        else
          echo -e "${RED}❌ Failed to enable auto sync. Please check ArgoCD permissions.${NC}"
          return 1
        fi
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
      echo "Sleeping for $rollout_status_check_interval seconds"
      sleep "${rollout_status_check_interval}"
      echo "End of loop"
      echo "==============================================================="
    done
  }

  # Print status header
  function print_header() {
    echo "========================================================"
    echo "🔍 Checking Argo Rollout status for:"
    echo "   - Cluster: ${CLUSTER_NAME}"
    echo "   - Region: ${AWS_REGION}"
    echo "   - Rollout: ${rollout_name}"
    echo "   - Namespace: ${namespace}"
    echo "   - Timeout: ${rollout_status_timeout}"
    echo "   - Check interval: ${rollout_status_check_interval}s"
    echo "--------------------------------------------------------"
  }

  set +e
  
  print_header

  # Export variables needed by the subshell invoked by timeout.
  export rollout_name namespace project_repo_name rollout_status_timeout rollout_status_check_interval
  export GREEN BLUE YELLOW RED NC
  export CLUSTER_NAME AWS_REGION

  local timeout_result=0
  timeout "${rollout_status_timeout}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f print_rollout_status_result rollout_is_progressing rollout_is_auto_sync_disabled get_auto_sync_enabled)
  $(declare -f is_not_found_error check_kubectl_auth refresh_kubeconfig get_kubectl_argo_rollout)
  $(declare -f with_argocd_cli set_argocd_cli unset_argocd_cli is_argocd_logged_in is_kubectl_namespace_set)
  $(declare -f update_kubeconfig)
  $(declare -f get_aws_credential_expiration_v1)
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
