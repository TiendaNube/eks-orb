#!/bin/bash

# -----------------------------------------------------------------------------
# argo_cli_common.sh
#
# Utility functions for preparing and cleaning up the ArgoCD CLI environment.
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
GREEN="\033[0;32m"
NC="\033[0m" # No Color

# Sets the kubectl context to the specified namespace and logs in to ArgoCD CLI.
# Arguments:
#   $1 - Namespace to set in the kubectl context.
function set_argocd_cli() {
  local namespace="$1"
  if ! kubectl config set-context --current --namespace="${namespace}"; then
    echo -e "${RED}❌ Failed to set kubectl context to namespace '${namespace}'${NC}"
    return 1
  fi
  if ! argocd login cd.argoproj.io --core; then
    echo -e "${RED}❌ Failed to login to ArgoCD CLI in namespace '${namespace}'${NC}"
    return 1
  fi
  echo -e "${GREEN}✅ ArgoCD CLI prepared for namespace '${namespace}'.${NC}"
}

# Resets the kubectl context to the default namespace.
function unset_argocd_cli() {
  if ! kubectl config set-context --current --namespace="default"; then
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
  if [[ $result -ne 0 ]]; then
    return $result
  fi

  # FIXME: Allow some time for the change to propagate.
  sleep 15
}
