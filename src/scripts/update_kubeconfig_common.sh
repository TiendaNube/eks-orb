# shellcheck disable=SC2148
#
# Script to update kubectl configuration for Amazon EKS.
# Provides a reusable function to update kubeconfig using AWS EKS authenticator.
# This script is intended to be sourced from other scripts.
#
# Usage:
#   source update_kubeconfig_common.sh
#
# Command-line arguments, which have higher precedence than environment variables:
#   --cluster-name          The name of the EKS cluster (required)
#   --aws-region            The AWS region where the cluster is located (optional)
#   --aws-profile           The AWS profile to use (optional)
#   --kubeconfig-file-path  Path to kubeconfig file (optional)
#   --role-arn              IAM role ARN to assume for cluster authentication (optional)
#   --cluster-context-alias Alias for the cluster context name (optional)
#   --dry-run               Print merged kubeconfig to stdout instead of writing (optional)
#   --verbose               Print detailed output (optional)
#
# Environment Variables (for auto-detection):
#   KUBECONFIG_CLUSTER_NAME - Cluster name (if not provided as parameter)
#   KUBECONFIG_AWS_REGION - AWS region (if not provided as parameter)
#   KUBECONFIG_AWS_PROFILE - AWS profile (if not provided as parameter)
#   KUBECONFIG_FILE_PATH - Path to kubeconfig file (if not provided as parameter)
#   KUBECONFIG_ROLE_ARN - IAM role ARN to assume for cluster authentication (if not provided as parameter)
#   KUBECONFIG_CLUSTER_CONTEXT_ALIAS - Alias for the cluster context name (if not provided as parameter)
#   KUBECONFIG_DRY_RUN - Print merged kubeconfig to stdout instead of writing (if not provided as parameter)
#   KUBECONFIG_VERBOSE - Print detailed output (if not provided as parameter)
#
# Returns:
#   - Exit code 0 on success
#   - Exit code 1 on failure

#shellcheck disable=SC2329
function update_kubeconfig() {
  local cluster_name="" aws_region="" aws_profile="" kubeconfig_file_path=""
  local role_arn="" cluster_context_alias="" dry_run=false verbose=false

  if [[ -n "${KUBECONFIG_CLUSTER_NAME:-}" ]]; then
    cluster_name="${KUBECONFIG_CLUSTER_NAME}"
  fi

  if [[ -n "${KUBECONFIG_AWS_REGION:-}" ]]; then
    aws_region="${KUBECONFIG_AWS_REGION}"
  fi

  if [[ -n "${KUBECONFIG_AWS_PROFILE:-}" ]]; then
    aws_profile="${KUBECONFIG_AWS_PROFILE}"
  fi

  if [[ -n "${KUBECONFIG_FILE_PATH:-}" ]]; then
    kubeconfig_file_path="${KUBECONFIG_FILE_PATH}"
  fi

  if [[ -n "${KUBECONFIG_ROLE_ARN:-}" ]]; then
    role_arn="${KUBECONFIG_ROLE_ARN}"
  fi

  if [[ -n "${KUBECONFIG_CLUSTER_CONTEXT_ALIAS:-}" ]]; then
    cluster_context_alias="${KUBECONFIG_CLUSTER_CONTEXT_ALIAS}"
  fi

  if [[ -n "${KUBECONFIG_DRY_RUN:-}" ]]; then
    dry_run="${KUBECONFIG_DRY_RUN}"
  fi

  if [[ -n "${KUBECONFIG_VERBOSE:-}" ]]; then
    verbose="${KUBECONFIG_VERBOSE}"
  fi

  # Parse command-line arguments, which override environment variables
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --cluster-name)
        cluster_name="$2"
        shift 2
        ;;
      --aws-region)
        aws_region="$2"
        shift 2
        ;;
      --aws-profile)
        aws_profile="$2"
        shift 2
        ;;
      --kubeconfig-file-path)
        kubeconfig_file_path="$2"
        shift 2
        ;;
      --role-arn)
        role_arn="$2"
        shift 2
        ;;
      --cluster-context-alias)
        cluster_context_alias="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --verbose)
        verbose=true
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  # Validate required parameters
  if [[ -z "$cluster_name" ]]; then
    echo "Error: Cluster name is required. Provide --cluster-name or set KUBECONFIG_CLUSTER_NAME environment variable." >&2
    return 1
  fi

  # Build aws eks update-kubeconfig command
  local cmd_args=()

  if [[ -n "$cluster_name" ]]; then
    cmd_args+=("--name" "$cluster_name")
  fi

  if [[ -n "$aws_region" ]]; then
    cmd_args+=("--region" "$aws_region")
  fi

  if [[ -n "$aws_profile" ]]; then
    cmd_args+=("--profile" "$aws_profile")
  fi

  if [[ -n "$kubeconfig_file_path" ]]; then
    cmd_args+=("--kubeconfig" "$kubeconfig_file_path")
  fi

  if [[ -n "$role_arn" ]]; then
    cmd_args+=("--role-arn" "$role_arn")
  fi

  if [[ -n "$cluster_context_alias" ]]; then
    cmd_args+=("--alias" "$cluster_context_alias")
  fi

  if [[ "$dry_run" == "true" ]]; then
    cmd_args+=("--dry-run")
  fi

  if [[ "$verbose" == "true" ]]; then
    cmd_args+=("--verbose")
  fi

  echo "cmd_args: ${cmd_args[*]}"

  # Execute the command
  aws eks update-kubeconfig "${cmd_args[@]}"
}
