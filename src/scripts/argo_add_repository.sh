#!/bin/bash

# This script registers a Git repository in ArgoCD using environment variables for configuration.
# It expects ARGO_CLI_COMMON_SCRIPT to be set and sources it for required functions.
# Usage: Set REPOSITORY_HTTP_URL, PROJECT, and optionally APPLICATION_NAMESPACE before running.

# Colors for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m" # No Color

# Validate that argocd CLI is available
if ! command -v argocd >/dev/null 2>&1; then
  echo -e "${RED}Error: argocd CLI is not installed or not in PATH.${NC}"
  exit 2
fi

# Validate that the ARGO_CLI_COMMON_SCRIPT variable is set
if [[ -z "${ARGO_CLI_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}Error: ARGO_CLI_COMMON_SCRIPT is empty${NC}"
  exit 2
fi

#shellcheck disable=SC1090
source <(echo "$ARGO_CLI_COMMON_SCRIPT")

# Check that the with_argocd_cli function is available
if ! declare -f with_argocd_cli > /dev/null; then
  echo -e "${RED}❌ with_argocd_cli function is not defined in subshell!${NC}"
  exit 2
fi

# Function to add a repository to ArgoCD
function add_repository() {
  local repo_url="$1"
  local project="$2"
  local application_namespace="$3"
  local repo_name="$4"
  if with_argocd_cli --namespace "${application_namespace}" -- argocd repo get "$repo_url" --project "$project"; then
    echo -e "${GREEN}✨ Repository $repo_url already registered in ArgoCD.${NC}"
  else
    if with_argocd_cli --namespace "${application_namespace}" -- argocd repo add "$repo_url" --project "$project" --name "$repo_name"; then
      echo -e "${GREEN}✅ Repository $repo_url successfully added to ArgoCD.${NC}"
    else
      echo -e "${RED}❌ Error: Failed to add repository to ArgoCD.${NC}" >&2
      exit 1
    fi
  fi
}

# Print usage instructions
function usage() {
  echo -e "${GREEN}Usage:${NC} Set the following environment variables before running this script:"
  echo "  REPOSITORY_HTTP_URL       Github repository URL (required)"
  echo "  PROJECT                   ArgoCD project name (required)"
  echo "  APPLICATION_NAMESPACE     Application namespace (required)"
  echo "  CIRCLE_PROJECT_REPONAME   Github repository name (required)"
}

function main() {
  # Read environment variables into local variables
  local repo_url="${REPOSITORY_HTTP_URL}"
  local project="${PROJECT}"  
  local application_namespace="${APPLICATION_NAMESPACE}"
  local repo_name="${CIRCLE_PROJECT_REPONAME}"

  # Validate required variables
  local missing_vars=()
  [[ -z "$repo_url" ]] && missing_vars+=("REPOSITORY_HTTP_URL")
  [[ -z "$project" ]] && missing_vars+=("PROJECT")
  [[ -z "$application_namespace" ]] && missing_vars+=("APPLICATION_NAMESPACE")
  [[ -z "$repo_name" ]] && missing_vars+=("CIRCLE_PROJECT_REPONAME")

  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo -e "${RED}Error: The following required environment variables are missing:${NC}"
    printf '  - %s\n' "${missing_vars[@]}"
    usage
    exit 2
  fi

  add_repository "$repo_url" "$project" "$application_namespace" "$repo_name"
}

main "$@"
