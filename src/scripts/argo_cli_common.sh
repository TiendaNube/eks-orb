#!/bin/bash

# -----------------------------------------------------------------------------
# argo_cli_common.sh
#
# Utility functions for preparing and cleaning up the ArgoCD CLI environment.
# Every command redirects stdout and stderr to null, to avoid adding extra output to the result of the command.
# This script is intended to be sourced from other scripts.
#
# Usage:
#   source argo_cli_common.sh
#   with_argocd_cli --namespace <namespace> -- <command> [args...]
#
# Notes:
# - The ArgoCD CLI requires the kubectl context namespace to match the target
#   Application's namespace for correct operation.
# - Functions are defined at the top level for portability and to avoid issues
#   when sourcing this script.
# - Color variables are defined for consistent output formatting.
# -----------------------------------------------------------------------------

# Colors for output
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

if ! command -v argocd >/dev/null 2>&1; then
  echo -e "${RED}❌ Error: argocd CLI is not installed or not in PATH.${NC}"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}❌ Error: jq is not installed or not in PATH.${NC}"
  exit 2
fi

# We use 'argocd app list' to check if the application exists. 
# We cannot use 'argocd app get' because it fails with PermissionDenied when the application is not found (masking the actual error).
function does_argocd_app_exist() {
  local application_namespace="$1"
  local release_name="$2"
  local output status

  output=$(with_argocd_cli --namespace "${application_namespace}" -- argocd app list -l "app=${release_name}" --output json)
  status=$?

  if [[ $status -ne 0 ]]; then
    echo -e "${RED}❌ Error: Unexpected failure querying ArgoCD Application '${release_name}'.${NC}"
    echo -e "${BLUE}📓 Output:${NC}\n${output}"
    return 1
  fi

  if [[ -z "$output" ]]; then
    echo -e "${RED}❌ Error: argocd app list command returned empty output.${NC}"
    return 1
  fi

  # Use jq to analyze the output is valid JSON
  if ! echo "$output" | jq empty 2>/dev/null; then
    echo -e "${RED}❌ Error: argocd app list command returned invalid JSON output.${NC}"
    echo -e "${BLUE}📓 Output:${NC}\n${output}"
    return 1
  fi

  # Application exists if JSON array has elements
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# Checks if an Argo Rollout exists in the specified namespace.
# Arguments:
#   $1 - Namespace where the rollout is deployed
#   $2 - Rollout name
# Returns:
#   0 - Rollout exists
#   1 - Rollout does not exist
#   2 - Unexpected error
function does_argocd_rollout_exist() {
  local namespace="$1"
  local rollout_name="$2"
  local output

  output=$(kubectl argo rollouts get rollout "${rollout_name}" --namespace "${namespace}" 2>&1)

  if [[ $? -eq 0 ]]; then
    return 0
  fi

  if [[ "$output" == *"not found"* ]]; then
    return 1
  fi

  echo -e "${RED}❌ Error: Unexpected failure querying Argo Rollout '${rollout_name}' in namespace '${namespace}'.${NC}"
  echo -e "${BLUE}📓 Output:${NC}\n${output}"
  return 2
}

function is_argocd_logged_in() {
  # Test authentication with a lightweight command
  # The command returns exit code 0 even when not logged in, but outputs "Logged In: false"
  local login_status
  login_status=$(argocd account get-user-info 2>/dev/null | grep "^Logged In:" | awk '{print $3}')
  [[ "$login_status" == "true" ]]
}

# Arguments:
#   $1 - Namespace to check
function is_kubectl_namespace_set() {
  local namespace="$1"
  local current_namespace
  current_namespace=$(kubectl config view --minify --output jsonpath='{..namespace}' 2>/dev/null)
  [[ "$current_namespace" == "$namespace" ]]
}

# Sets the kubectl context to the specified namespace and logs in to ArgoCD CLI.
# Arguments:
#   $1 - Namespace to set in the kubectl context.
function set_argocd_cli() {
  local namespace="$1"
  
  if ! is_kubectl_namespace_set "$namespace"; then
    if ! kubectl config set-context --current --namespace="${namespace}" >/dev/null 2>&1; then
      echo -e "${RED}❌ Failed to set kubectl context to namespace '${namespace}'${NC}"
      return 1
    fi
  fi

  if ! is_argocd_logged_in; then
    if ! argocd login cd.argoproj.io --core >/dev/null 2>&1; then
      echo -e "${RED}❌ Failed to login to ArgoCD CLI in namespace '${namespace}'${NC}"
      return 1
    fi
  fi
}

# Resets the kubectl context to the default namespace.
function unset_argocd_cli() {
  if ! kubectl config set-context --current --namespace="default" >/dev/null 2>&1; then
    echo -e "${RED}❌ Failed to reset kubectl context to default namespace.${NC}"
    return 1
  fi 
}

# Prepares the ArgoCD CLI environment, runs the given command, and then cleans up.
# Usage:
#   with_argocd_cli --namespace <namespace> -- <command> [args...]
# Example:
#   with_argocd_cli --namespace my-namespace -- argocd app list
# Arguments:
#   --namespace <namespace> : (Required) Namespace to use for ArgoCD CLI.
#   --                      : (Required) Separator before the command to run.
#   <command> [args...]     : Command and arguments to execute within the prepared environment.
function with_argocd_cli() {
  local namespace=""

  # Parse flags
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo -e "${RED}Unknown flag: $1${NC}"; return 1 ;;
    esac
  done

  if [[ -z "$namespace" ]]; then
    echo -e "${RED}❌ --namespace flag is required.${NC}"
    return 1
  fi

  # FIXME: The ArgoCD CLI has a limitation when connecting using the kubectl context:
  # It requires the configured namespace to be the one where the target Application is created.
  # This is necessary for CLI operations to work correctly on.
  # We can check in the future if we can use a different approach when upgrading ArgoCD.

  set_argocd_cli "$namespace" || return 1
  "$@"
  local result=$?
  unset_argocd_cli
  return $result
}
