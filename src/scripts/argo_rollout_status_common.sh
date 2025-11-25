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
    # This proactively checks if the token is still valid before attempting operations
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
  function get_aws_credential_expiration_v1() {
    # Function to get AWS_CREDENTIAL_EXPIRATION compatible with AWS CLI v1
    # Equivalent to: aws configure export-credentials --format env-no-export --profile <profile>
    local profile="${AWS_PROFILE:-${KUBECONFIG_AWS_PROFILE:-default}}"
    local aws_credentials_file="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
    local expiration=""
    local session_token=""
    local aws_region="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"

    echo "------------------------------------------------------"
    echo "🔍 Searching for AWS credential expiration"
    echo "   Profile: ${profile}"
    echo "   Credentials file: ${aws_credentials_file}"
    echo "   AWS Region: ${aws_region}"
    echo "------------------------------------------------------"

    # Method 0: Check if already set in environment (highest priority)
    # Some CI/CD systems or orbs may set this directly
    echo "📋 Method 0: Checking environment variable AWS_CREDENTIAL_EXPIRATION..."
    if [[ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]]; then
      expiration="${AWS_CREDENTIAL_EXPIRATION}"
      echo -e "${GREEN}✅ Found expiration in environment: ${expiration}${NC}"
    else
      echo -e "${YELLOW}⚠️  Not found in environment${NC}"
    fi

    # Method 1: Read from ~/.aws/credentials file using awk
    if [[ -z "$expiration" ]] && [[ -f "$aws_credentials_file" ]]; then
      echo "------------------------------------------------------"
      echo "📋 Method 1: Reading from credentials file..."
      echo "📄 AWS Credentials File: ${aws_credentials_file}"
      echo "------------------------------------------------------"
      expiration=$(awk -v p="$profile" '
        BEGIN { in_section = 0 }
        /^\[.*\]/ { 
          in_section = ($0 ~ "^\\[" p "\\]") || ($0 ~ "^\\[profile " p "\\]")
        }
        in_section && /^[[:space:]]*expiration[[:space:]]*=/ {
          sub(/^[[:space:]]*expiration[[:space:]]*=[[:space:]]*/, "")
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          print
          exit
        }
      ' "$aws_credentials_file")
      
      if [[ -n "$expiration" ]]; then
        echo -e "${GREEN}✅ Found expiration in credentials file: ${expiration}${NC}"
      else
        echo -e "${YELLOW}⚠️  Expiration field not found in credentials file${NC}"
        
        # Also check for session_token while we're at it (for Method 4)
        echo "🔍 Checking for session_token in credentials file..."
        session_token=$(awk -v p="$profile" '
          BEGIN { in_section = 0 }
          /^\[.*\]/ { 
            in_section = ($0 ~ "^\\[" p "\\]") || ($0 ~ "^\\[profile " p "\\]")
          }
          in_section && /^[[:space:]]*aws_session_token[[:space:]]*=/ {
            sub(/^[[:space:]]*aws_session_token[[:space:]]*=[[:space:]]*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
          }
        ' "$aws_credentials_file")
        
        if [[ -n "$session_token" ]]; then
          echo -e "${BLUE}ℹ️  Found session_token (temporary credentials detected)${NC}"
        else
          echo -e "${YELLOW}⚠️  No session_token found (credentials may be permanent)${NC}"
        fi
      fi
    elif [[ ! -f "$aws_credentials_file" ]]; then
      echo -e "${RED}❌ AWS credentials file not found: ${aws_credentials_file}${NC}"
    fi
    
    # Method 2: Search in CLI cache if not found (most recent file first)
    # This is where AWS CLI v1 stores temporary credentials from assume-role, etc.
    if [[ -z "$expiration" ]]; then
      echo "------------------------------------------------------"
      echo "📋 Method 2: Searching in CLI cache..."
      echo "   Cache directory: ${HOME}/.aws/cli/cache"
      echo "------------------------------------------------------"
      if [[ -d "$HOME/.aws/cli/cache" ]]; then
        if command -v jq &> /dev/null; then
          echo "🔍 Using jq to search cache files..."
          local cache_file
          local cache_count=0
          while IFS= read -r -d '' cache_file; do
            cache_count=$((cache_count + 1))
            echo "   Checking cache file ${cache_count}: $(basename "$cache_file")"
            expiration=$(jq -r '.Credentials.Expiration // empty' "$cache_file" 2>/dev/null)
            if [[ -n "$expiration" ]] && [[ "$expiration" != "null" ]] && [[ "$expiration" != "" ]]; then
              echo -e "${GREEN}✅ Found expiration in cache: ${expiration}${NC}"
              break
            fi
          done < <(find "$HOME/.aws/cli/cache" -name "*.json" -type f -print0 2>/dev/null | sort -z -r)
          if [[ -z "$expiration" ]]; then
            echo -e "${YELLOW}⚠️  No expiration found in ${cache_count} cache file(s)${NC}"
          fi
        else
          echo "🔍 Using grep to search cache files (jq not available)..."
          local cache_file
          while IFS= read -r -d '' cache_file; do
            expiration=$(grep -o '"Expiration"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache_file" 2>/dev/null | head -1 | sed 's/.*"Expiration"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            if [[ -n "$expiration" ]]; then
              echo -e "${GREEN}✅ Found expiration in cache: ${expiration}${NC}"
              break
            fi
          done < <(find "$HOME/.aws/cli/cache" -name "*.json" -type f -print0 2>/dev/null | sort -z -r)
        fi
      else
        echo -e "${YELLOW}⚠️  AWS CLI cache directory not found: ${HOME}/.aws/cli/cache${NC}"
      fi
    fi
    
    # Method 3: Try to read from alternative locations where CI/CD systems might store it
    # Some systems write expiration to a separate file or use different cache locations
    if [[ -z "$expiration" ]]; then
      echo "------------------------------------------------------"
      echo "📋 Method 3: Checking SSO cache..."
      echo "   SSO cache directory: ${HOME}/.aws/sso/cache"
      echo "------------------------------------------------------"
      if [[ -d "$HOME/.aws/sso/cache" ]]; then
        local sso_cache_file
        local sso_count=0
        while IFS= read -r -d '' sso_cache_file; do
          sso_count=$((sso_count + 1))
          echo "   Checking SSO cache file ${sso_count}: $(basename "$sso_cache_file")"
          if command -v jq &> /dev/null; then
            expiration=$(jq -r '.expiresAt // empty' "$sso_cache_file" 2>/dev/null)
            if [[ -n "$expiration" ]] && [[ "$expiration" != "null" ]] && [[ "$expiration" != "" ]]; then
              echo -e "${GREEN}✅ Found expiration in SSO cache: ${expiration}${NC}"
              break
            fi
          fi
        done < <(find "$HOME/.aws/sso/cache" -name "*.json" -type f -print0 2>/dev/null | sort -z -r)
        if [[ -z "$expiration" ]]; then
          echo -e "${YELLOW}⚠️  No expiration found in SSO cache${NC}"
        fi
      else
        echo -e "${YELLOW}⚠️  SSO cache directory not found${NC}"
      fi
    fi
    
    # Method 4: Get expiration from AWS API by decoding session token or making API call
    if [[ -z "$expiration" ]]; then
      echo "------------------------------------------------------"
      echo "📋 Method 4: Attempting to get expiration from AWS API..."
      echo "------------------------------------------------------"
      
      # First, get the session_token if we don't have it yet
      if [[ -z "$session_token" ]] && [[ -f "$aws_credentials_file" ]]; then
        echo "🔍 Retrieving session_token from credentials file..."
        session_token=$(awk -v p="$profile" '
          BEGIN { in_section = 0 }
          /^\[.*\]/ { 
            in_section = ($0 ~ "^\\[" p "\\]") || ($0 ~ "^\\[profile " p "\\]")
          }
          in_section && /^[[:space:]]*aws_session_token[[:space:]]*=/ {
            sub(/^[[:space:]]*aws_session_token[[:space:]]*=[[:space:]]*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
          }
        ' "$aws_credentials_file")
      fi
      
      if [[ -n "$session_token" ]]; then
        echo -e "${BLUE}ℹ️  Session token found, attempting to decode or query AWS API...${NC}"
        
        # Try to decode the session token (AWS session tokens are base64-encoded JSON)
        # The token format is: base64(header).base64(payload).signature
        # The payload contains expiration information
        if command -v base64 &> /dev/null; then
          echo "🔍 Attempting to decode session token..."
          # Extract the payload (second part of the token)
          local token_payload
          token_payload=$(echo "$session_token" | cut -d'.' -f2 2>/dev/null)
          
          if [[ -n "$token_payload" ]]; then
            # Add padding if needed and decode
            local padding=$((4 - ${#token_payload} % 4))
            if [[ $padding -ne 4 ]]; then
              token_payload="${token_payload}$(printf '%*s' $padding | tr ' ' '=')"
            fi
            
            local decoded_payload
            decoded_payload=$(echo "$token_payload" | base64 -d 2>/dev/null)
            
            if [[ -n "$decoded_payload" ]] && command -v jq &> /dev/null; then
              expiration=$(echo "$decoded_payload" | jq -r '.exp // .expiration // empty' 2>/dev/null)
              if [[ -n "$expiration" ]] && [[ "$expiration" != "null" ]]; then
                # Convert Unix timestamp to ISO 8601 format if needed
                if [[ "$expiration" =~ ^[0-9]+$ ]]; then
                  if command -v date &> /dev/null; then
                    expiration=$(date -u -d "@${expiration}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "${expiration}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$expiration")
                  fi
                fi
                echo -e "${GREEN}✅ Found expiration in decoded token: ${expiration}${NC}"
              fi
            fi
          fi
        fi
        
        # If decoding didn't work, try to get expiration via AWS API
        # Note: This requires making an API call, which may have costs or rate limits
        if [[ -z "$expiration" ]]; then
          echo "🔍 Attempting to get expiration via AWS STS API call..."
          echo "   Note: This makes an actual API call to AWS"
          
          local profile_args=()
          [[ "$profile" != "default" ]] && profile_args=("--profile" "$profile")
          
          # First, verify credentials work
          local sts_output
          if sts_output=$(aws sts get-caller-identity "${profile_args[@]}" --region "$aws_region" --output json 2>&1); then
            echo -e "${GREEN}✅ AWS API call successful (credentials are valid)${NC}"
            
            # Try to extract role ARN from the response (if credentials are from assume-role)
            local role_arn
            if command -v jq &> /dev/null; then
              role_arn=$(echo "$sts_output" | jq -r '.Arn // empty' 2>/dev/null)
              echo "   Current identity ARN: ${role_arn}"
              
              # If the ARN contains "assumed-role", we can try to get expiration from the role session
              # However, AWS doesn't provide an API to get expiration of existing credentials
              # The only way is if the credentials were obtained via assume-role and we have the response
              
              # Check if we can find the role ARN in config file to potentially re-assume it
              # (but we won't do that as it would create new credentials)
              echo -e "${YELLOW}⚠️  AWS API doesn't provide expiration in get-caller-identity response${NC}"
              echo -e "${YELLOW}⚠️  Cannot determine expiration without it being stored locally${NC}"
              echo -e "${BLUE}ℹ️  Credentials are valid and working, but expiration info is not available${NC}"
            else
              echo -e "${YELLOW}⚠️  jq not available to parse response${NC}"
            fi
            
            # Alternative approach: Try to get expiration by making a test call and checking response headers
            # Some AWS services return expiration in response metadata, but STS doesn't
            echo "🔍 Checking if expiration can be obtained from response metadata..."
            # Unfortunately, AWS STS doesn't return expiration in response metadata
            echo -e "${YELLOW}⚠️  Expiration not available in API response${NC}"
          else
            echo -e "${RED}❌ AWS API call failed: ${sts_output}${NC}"
            echo -e "${RED}❌ Cannot verify credentials or get expiration information${NC}"
          fi
        fi
      else
        echo -e "${YELLOW}⚠️  No session_token found - credentials may be permanent (no expiration)${NC}"
      fi
    fi
    
    # Export in the expected format (without "export" as in env-no-export)
    echo "------------------------------------------------------"
    if [[ -n "$expiration" ]]; then
      echo -e "${GREEN}✅ FINAL RESULT: AWS_CREDENTIAL_EXPIRATION=${expiration}${NC}"
      echo "AWS_CREDENTIAL_EXPIRATION=${expiration}"
    else
      echo -e "${RED}❌ FINAL RESULT: No AWS credential expiration found${NC}"
      echo -e "${YELLOW}⚠️  Credentials will work, but expiration information is not available${NC}"
    fi
    echo "------------------------------------------------------"
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

    while true; do
      echo "** DEBUG AWS EXPIRATION *************************************"
      # Use AWS CLI v1 compatible function instead of v2's export-credentials
      # aws configure export-credentials --format env-no-export
      get_aws_credential_expiration_v1
      echo "*************************************************************"
      echo "============================================================="
      echo "🔍 Checking Rollout / Application status (attempt $i)..."
      # Get kubectl rollout status (handles errors and retries internally)
      kubectl_output=$(get_kubectl_argo_rollout "${rollout_name}" "${namespace}") || return $?
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
      sleep "${rollout_status_check_interval}"
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
