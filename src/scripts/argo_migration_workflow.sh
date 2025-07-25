#!/bin/bash

# Colors for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

if [[ -z "${ROLLOUT_STATUS_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}Error: ROLLOUT_STATUS_COMMON_SCRIPT is empty${NC}"
  exit 2
fi

source <(echo "$ROLLOUT_STATUS_COMMON_SCRIPT")

# Check that exec_rollout_status function exists
if ! declare -f exec_rollout_status > /dev/null; then
  echo -e "${RED}Error: exec_rollout_status function is not defined after sourcing ROLLOUT_STATUS_COMMON_SCRIPT${NC}"
  exit 2
fi

declare -A ARGOCD_URLS=(
  [production]="https://prod-argocd.linkedstore.com/applications"
  [staging]="https://argocd.nubestaging.com/applications/argocd"
)

# Returns the ArgoCD URL for a given profile and application name.
# Arguments:
#   $1 - Profile name (e.g., production, staging)
#   $2 - Application name
function get_argocd_url() {
  local profile="$1"
  local application_name="$2"
  local base_url="${ARGOCD_URLS[$profile]}"
  if [[ -n "$base_url" ]]; then
    echo "${base_url}/${application_name}"
  else
    echo -e "${RED}Error: No ArgoCD URL configured for profile '$profile'. Available profiles: ${!ARGOCD_URLS[@]}${NC}"
    exit 1
  fi
}

# Prints a help message describing the migration phase.
# Arguments:
#   $1 - Color code for output
#   $2 - Prefix for the message
#   $3 - Phase name (safe, initial, traffic, completed)
print_phase_help() {
  local color="$1"
  local prefix="$2"
  local phase="$3"
  [[ -z "$phase" ]] && { echo -e "${RED}❌ No phase specified.${NC}"; return 1; }

  _print_colored() {
    local color="$1"
    shift
    echo -e "${color}$*${NC}"
  }

  case "$phase" in
    "safe")
      _print_colored "$color" "$(cat <<EOF
  🛡️  $prefix 'safe':
    - Starting point with minimal changes.
    - All existing resources become managed by the ArgoCD Application.
    - Triggers a rolling update for the Deployment.
    - Creates a Rollout resource (with zero replicas) and new Service definitions.
    - Traffic still flows to the Deployment.
    - Monitor DataDog dashboards to ensure no issues arise.
EOF
)"
      ;;
    "initial")
      _print_colored "$color" "$(cat <<EOF
  🚀 $prefix 'initial':
    - The Rollout starts with replicas for the first time.
    - Deployment and Rollout coexist with duplicated replicas.
    - Traffic remains with the Deployment.
    - You can test the new Rollout replicas using the header: "x-nube-local-canary: true" (NOT supported for NGINX Ingress).
    - Validate that Rollout pods are healthy and ready for real traffic.
EOF
)"
      ;;
    "traffic")
      _print_colored "$color" "$(cat <<EOF
  🌐 $prefix 'traffic':
    - Most critical step: traffic is routed to the Rollout pods.
    - Deployment and its replicas are kept temporarily for fast rollback.
    - Closely monitor the system to ensure proper traffic processing.
EOF
)"
      ;;
    "completed")
      _print_colored "$color" "$(cat <<EOF
  ✅ $prefix 'completed':
    - Migration finalizes: Deployment and legacy Service are removed.
    - Canary analysis runs for the first time to validate stability.
    - Confirm the analysis completes successfully to finish the migration.
EOF
)"
      ;;
    *)
      _print_colored "$RED" "❌ Unknown phase: $phase"
      return 1
      ;;
  esac
}

# Waits for user feedback via an ArgoCD Application annotation and applies the result.
# Arguments:
#   $1 - Current phase
#   $2 - Next phase (if proceeding)
#   $3 - Namespace of the ArgoCD Application
#   $4 - Name of the ArgoCD Application
#   $5 - Profile name
function await_and_apply_feedback() {

  # Export variables so they are available in the environment of the subshell
  # executed by 'timeout'. This is necessary because 'timeout' runs the command
  # in a new bash process, and only exported variables are accessible there.
  export current_phase="$1"
  export next_phase="$2"
  export namespace="$3"
  export application_name="$4"
  export profile_name="$5"
  export annotation_key="${FEEDBACK_ANNOTATION_KEY:-migration.argocd.io/approval-next-phase}"
  export feedback_check_interval="${FEEDBACK_CHECK_INTERVAL:-10}"

  function handle_feedback_decision() {

    function delete_annotation() {
      if ! kubectl annotate applications -n "${namespace}" "${application_name}" "${annotation_key}-" --overwrite; then
        echo -e "${RED}❌ Failed to delete annotation ${annotation_key}${NC}"
        exit 1
      fi
      echo -e "${YELLOW}🗑️ Deleted annotation ${annotation_key} for future reuse${NC}"
    }

    function set_argocd_cli() {
      if ! kubectl config set-context --current --namespace="${namespace}"; then
        echo -e "${RED}❌ Failed to set kubectl context to namespace '${namespace}'${NC}"
        exit 1
      fi
      if ! argocd login cd.argoproj.io --core; then
        echo -e "${RED}❌ Failed to login to ArgoCD CLI in namespace '${namespace}'${NC}"
        exit 1
      fi
      echo -e "${GREEN}✅ ArgoCD CLI prepared for namespace '${namespace}'.${NC}"
    }

    function unset_argocd_cli() {
      if ! kubectl config set-context --current --namespace="default"; then
        echo -e "${RED}❌ Failed to reset kubectl context to default namespace.${NC}"
        exit 1
      fi 
    }

    # FIXME: The ArgoCD CLI has a limitation when connecting using the kubectl context:
    # It requires the configured namespace to be the one where the target Application is created.
    # This is necessary for CLI operations to work correctly on. 
    # We can check in the future if we can use a different approach when upgrading ArgoCD.
    function with_argocd_cli() {
      set_argocd_cli
      "$@"
      local result=$?
      unset_argocd_cli
      if [[ $result -ne 0 ]]; then
        return $result
      fi
      # FIXME: Allow some time for the change to propagate. We should query the Application status.
      sleep 15
    }

    function set_next_phase() {
      if ! with_argocd_cli argocd app set "${application_name}" --helm-set canaryMigrationPhaseOverride="${next_phase}"; then
        echo -e "${RED}❌ Failed to set next phase to '${next_phase}'${NC}"
        exit 1
      fi
      echo -e "${GREEN}✅ Next phase set to '${next_phase}'${NC}"
    }

    function rollback_migration() {
      if ! with_argocd_cli argocd app set "${application_name}" --helm-set canaryMigrationPhaseOverride=safe; then
        echo -e "${RED}❌ Failed to rollback migration to safe phase${NC}"
        exit 1
      fi
      echo -e "${GREEN}✅ Migration rolled back to safe phase${NC}"
    }

    while true; do
      status=$(kubectl get applications -n "${namespace}" "${application_name}" -o jsonpath="{.metadata.annotations.${annotation_key//./\\.}}")
      if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ Failed to get application status. Retrying in ${feedback_check_interval} seconds...${NC}"
        sleep $feedback_check_interval
        continue
      fi
      if [[ -z "$status" ]]; then
        printf "."  # Print a dot on the same line for each wait iteration
        sleep $feedback_check_interval
        continue
      fi
      echo -e "\n${BLUE}🔍 Found annotation '${annotation_key}' with value: ${status}${NC}"
      case "$status" in
        "proceed")
          echo -e "${GREEN}✅ User feedback is to PROCEED with deployment${NC}"
          delete_annotation
          if [[ -n "${next_phase}" ]]; then
            set_next_phase
            exec_rollout_status
          fi
          exit $?
          ;;
        "rollback")
          echo -e "${YELLOW}⚠️ User feedback is to ROLLBACK deployment${NC}"
          delete_annotation
          rollback_migration
          exec_rollout_status # Ignore its exit code
          exit 5 # We want to exit with an error code to indicate rollback
          ;;
        *)
          echo -e "${YELLOW}⚠️ Unknown feedback value: '$status', will retry in $feedback_check_interval seconds${NC}"
          sleep $feedback_check_interval
          ;;
      esac
    done
  }

  local feedback_timeout="${FEEDBACK_TIMEOUT:-30m}"

  local argocd_url
  argocd_url=$(get_argocd_url "$profile_name" "$application_name")

  echo "=================================================================================================================="
  echo -e "${BLUE}🔗 You can view your stack in ArgoCD here:${NC} $argocd_url"
  echo "=================================================================================================================="
  print_phase_help "$YELLOW" "Current migration phase is" "$current_phase"
  echo "=================================================================================================================="
  if [[ "$current_phase" == "completed" && "$next_phase" == "" ]]; then
    echo -e "${GREEN}✅ Migration is in the 'completed' phase."
    echo -e "   Please confirm everything is stable, or request a rollback if needed. Awaiting final user confirmation before closing workflow."
  else
    print_phase_help "$GREEN" "Next step if you proceed is" "$next_phase"
  fi
  echo "=================================================================================================================="
  echo -e "${BLUE}ℹ️  Please use the ArgoCD UI to add the following annotation to the application:${NC}"
  echo "    Key:   ${annotation_key}"
  echo "    Value: proceed   (to continue)  OR  rollback   (to rollback)"
  echo "   (In the ArgoCD UI, go to the Application, click 'Details', then 'Edit', and add the annotation.)"
  echo "=================================================================================================================="

  set +e

  # To ensure colors are available in the subshell, we export them
  export RED GREEN YELLOW BLUE NC

  timeout "${feedback_timeout}" bash -o pipefail -c "$(declare -f handle_feedback_decision exec_rollout_status); handle_feedback_decision"
  timeout_result=$?

  if [[ $timeout_result -eq 124 ]]; then
    echo -e "${RED}⏰ Timeout reached while waiting for user feedback.${NC}"
    return 1
  elif [[ $timeout_result -eq 5 ]]; then
    echo -e "${RED}❌ Migration workflow aborted due to rollback.${NC}"
    return 5
  elif [[ $timeout_result -ne 0 ]]; then
    echo -e "${RED}❌ Migration workflow aborted due to error (exit code: $timeout_result).${NC}"
    return $timeout_result
  fi
}

# Drives the migration workflow, iterating through each migration phase and waiting for user feedback at each step.
# Reads required variables from the environment and profile file.
function exec_migration_workflow() {
  local application_name namespace rollout_name profile_file_name

  application_name="${APPLICATION_NAME}"
  namespace="${NAMESPACE}"
  rollout_name="${ROLLOUT_NAME}"
  profile_file_name="${PROFILE_FILE_NAME}"
  application_namespace=${APPLICATION_NAMESPACE:-argocd}

  if [[ -z "$application_name" ]] || [[ -z "$namespace" ]] || [[ -z "$rollout_name" ]] || [[ -z "$profile_file_name" ]]; then
    echo -e "${RED}Error: Missing required variables for ArgoCD application migration.${NC}"
    echo -e "${RED}  APPLICATION_NAME:        '${application_name}'${NC}"
    echo -e "${RED}  NAMESPACE:               '${namespace}'${NC}"
    echo -e "${RED}  ROLLOUT_NAME:            '${rollout_name}'${NC}"
    echo -e "${RED}  PROFILE_FILE_NAME:       '${profile_file_name}'${NC}"
    echo -e "${RED}Please ensure all required environment variables are set and not empty.${NC}"
    exit 2
  fi

  if [[ ! -f "$profile_file_name" ]]; then
    echo -e "${RED}Error: Profile file '$profile_file_name' not found.${NC}"
    exit 2
  fi

  echo "=================================================================================================================="
  echo -e "${BLUE}🔍 Migration Workflow Context:${NC}"
  echo "   - Application Name:        ${application_name}"
  echo "   - Namespace:               ${namespace}"
  echo "   - Rollout Name:            ${rollout_name}"
  echo "   - Application Namespace:   ${application_namespace}"
  echo "   - Profile File:            ${profile_file_name}"
  echo "   - Profile File Content:"
  echo "--------------------------------------------------"
  cat -n "${profile_file_name}"
  echo "--------------------------------------------------"
  echo "=================================================================================================================="

  local phase_value
  phase_value=$(yq '.canaryMigrationPhaseOverride' "$profile_file_name" | tr -d '\n')  

  # If migration is already completed, skip the rest
  if [[ "$phase_value" == "completed" ]]; then
    echo -e "${GREEN}Migration is already completed. No further actions are required.${NC}"
    exit 0
  fi

  # Define the ordered list of phases
  local phases=("safe" "initial" "traffic" "completed")
  local start_index=-1

  # Find the current phase index
  for i in "${!phases[@]}"; do
    if [[ "${phases[$i]}" == "$phase_value" ]]; then
      start_index=$i
      break
    fi
  done

  # Check if phase is valid
  if [[ "$start_index" -eq -1 ]]; then
    echo -e "${RED}Unknown phase value in $profile_file_name: $phase_value${NC}"
    exit 2
  fi

  local profile_name
  profile_name=$(yq '.profileName' "$profile_file_name" | tr -d '\n')

  if [[ -z "$profile_name" ]]; then
    echo -e "${RED}Error: Profile name is empty in $profile_file_name.${NC}"
    exit 2
  fi

  # Iterate through remaining phases
  local current_phase="${phases[$start_index]}"
  for ((i=start_index+1; i<${#phases[@]}; i++)); do
    local result=0
    local next_phase="${phases[$i]}"
    await_and_apply_feedback "$current_phase" "$next_phase" "$application_namespace" "$application_name" "$profile_name" || result=$?
    if [[ $result -ne 0 ]]; then
      exit $result
    fi
    current_phase="$next_phase"
  done

  # Final feedback after 'completed' phase
  local final_result=0
  await_and_apply_feedback "completed" "" "$application_namespace" "$application_name" "$profile_name" || final_result=$?
  if [[ $final_result -ne 0 ]]; then
    exit $final_result
  fi

  echo -e "${GREEN}🎉 Migration workflow completed successfully!${NC}"
}

exec_migration_workflow
