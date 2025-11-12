#!/bin/bash

# --- Color codes for output ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# --- Validate required environment scripts ---
if [[ -z "${ROLLOUT_STATUS_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: ROLLOUT_STATUS_COMMON_SCRIPT is empty${NC}"
  exit 2
fi
if [[ -z "${ARGO_CLI_COMMON_SCRIPT:-}" ]]; then
  echo -e "${RED}❌ Error: ARGO_CLI_COMMON_SCRIPT is empty${NC}"
  exit 2
fi

# --- Validate required dependencies ---
for cmd in yq kubectl timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}Error: $cmd is not installed or not in PATH.${NC}"
    exit 2
  fi
done

# --- ArgoCD URLs by profile ---
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
    return 1
  fi
}

# Prints a help message describing the migration phase.
# Arguments:
#   $1 - Color code for output
#   $2 - Prefix for the message
#   $3 - Phase name (safe, initial, traffic, completed)
function print_phase_help() {
  local color="$1"
  local prefix="$2"
  local phase="$3"
  [[ -z "$phase" ]] && { echo -e "${RED}❌ No phase specified.${NC}"; return 1; }

  function _print_colored() {
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

# --- Handles feedback loop for migration phase ---
function handle_feedback_decision() {

  #shellcheck disable=SC1090
  source <(echo "$ROLLOUT_STATUS_COMMON_SCRIPT")

  # Validate required functions.
  # with_argocd_cli is defined in ARGO_CLI_COMMON_SCRIPT, but will be sourced by ROLLOUT_STATUS_COMMON_SCRIPT.
  for fn in with_argocd_cli exec_rollout_status; do
    if ! declare -f "$fn" > /dev/null; then
      echo -e "${RED}❌ $fn function is not defined in subshell!${NC}"
      exit 2
    fi
  done

  function delete_annotation() {
    if ! kubectl annotate applications -n "${application_namespace}" "${application_name}" "${feedback_annotation_key}-" --overwrite; then
      echo -e "${RED}❌ Failed to delete annotation ${feedback_annotation_key}${NC}"
      return 1
    fi
    echo -e "${YELLOW}🗑️ Deleted annotation ${feedback_annotation_key} for future reuse${NC}"
  }

  function set_next_phase() {
    if ! with_argocd_cli --namespace "${application_namespace}" -- argocd app set "${application_name}" --source-name main-helm-chart --helm-set canaryMigrationPhaseOverride="${next_phase}"; then
      echo -e "${RED}❌ Failed to set next phase to '${next_phase}'${NC}"
      return 1
    fi
    echo -e "${GREEN}✅ Next phase set to '${next_phase}'${NC}"
  }

  function rollback_migration() {
    if ! with_argocd_cli --namespace "${application_namespace}" -- argocd app set "${application_name}" --source-name main-helm-chart --helm-set canaryMigrationPhaseOverride=safe; then
      echo -e "${RED}❌ Failed to rollback migration to safe phase${NC}"
      return 1
    fi
    echo -e "${GREEN}✅ Migration rolled back to safe phase${NC}"
  }

  function trigger_rollout_status() {
    exec_rollout_status \
      --rollout-name "${rollout_name}" \
      --namespace "${namespace}" \
      --project-repo-name "${project_repo_name}" \
      --timeout "${rollout_status_timeout}" \
      --interval "${rollout_status_check_interval}"
  }

  while true; do
    local status
    status=$(kubectl get applications -n "${application_namespace}" "${application_name}" -o jsonpath="{.metadata.annotations.${feedback_annotation_key//./\\.}}")
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
    echo -e "\n${BLUE}🔍 Found annotation '${feedback_annotation_key}' with value: ${status}${NC}"
    case "$status" in
      "proceed")
        echo -e "${GREEN}✅ User feedback is to PROCEED with deployment${NC}"
        delete_annotation || exit $?
        if [[ -n "${next_phase}" ]]; then
          set_next_phase || exit $?
          trigger_rollout_status || exit $?
        fi
        exit 0 # Exit with success code
        ;;
      "rollback")
        echo -e "${YELLOW}⚠️ User feedback is to ROLLBACK deployment${NC}"
        delete_annotation || exit $?
        rollback_migration || exit $?
        trigger_rollout_status || true
        exit 5 # We want to exit with an error code to indicate rollback
        ;;
      *)
        echo -e "${YELLOW}⚠️ Unknown feedback value: '$status', will retry in $feedback_check_interval seconds${NC}"
        sleep $feedback_check_interval
        ;;
    esac
  done
}

# Waits for user feedback via an ArgoCD Application annotation and applies the result.
function await_and_apply_feedback() {

  # Parse flags
  current_phase="" next_phase="" namespace="" application_name="" application_namespace="" profile_name="" rollout_name=""
  feedback_annotation_key="" feedback_check_interval="" feedback_timeout=""
  rollout_status_timeout="" rollout_status_check_interval="" project_repo_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --current-phase) current_phase="$2"; shift 2 ;;
      --next-phase) next_phase="$2"; shift 2 ;;
      --namespace) namespace="$2"; shift 2 ;;
      --application-name) application_name="$2"; shift 2 ;;
      --application-namespace) application_namespace="$2"; shift 2 ;;
      --project-repo-name) project_repo_name="$2"; shift 2 ;;
      --rollout-status-timeout) rollout_status_timeout="$2"; shift 2 ;;
      --rollout-status-check-interval) rollout_status_check_interval="$2"; shift 2 ;;
      --rollout-name) rollout_name="$2"; shift 2 ;;
      --profile-name) profile_name="$2"; shift 2 ;;
      --feedback-annotation-key) feedback_annotation_key="$2"; shift 2 ;;
      --feedback-check-interval) feedback_check_interval="$2"; shift 2 ;;
      --feedback-timeout) feedback_timeout="$2"; shift 2 ;;
      *) echo -e "${RED}Unknown flag: $1${NC}"; return 2 ;;
    esac
  done

  local argocd_url
  argocd_url=$(get_argocd_url "$profile_name" "$application_name") || exit $?

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
  echo "    Key:   ${feedback_annotation_key}"
  echo "    Value: proceed   (to continue)  OR  rollback   (to rollback)"
  echo "   (In the ArgoCD UI, go to the Application, click 'Details', then 'Edit', and add the annotation.)"
  echo "=================================================================================================================="

  set +e

  # Export variables needed by the subshell invoked by timeout.
  export current_phase next_phase namespace application_name application_namespace profile_name rollout_name project_repo_name
  export feedback_annotation_key feedback_check_interval feedback_timeout
  export rollout_status_timeout rollout_status_check_interval
  export RED GREEN YELLOW BLUE NC
  export ARGO_CLI_COMMON_SCRIPT ROLLOUT_STATUS_COMMON_SCRIPT

  local timeout_result=0
  timeout "${feedback_timeout}" bash -o pipefail -c "$(cat <<EOF
  $(declare -f handle_feedback_decision)
  handle_feedback_decision
EOF
)" || timeout_result=$?

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
# Reads required variables from the environment.
function exec_migration_workflow() {

  local project_repo_name="${PROJECT_REPO_NAME}"
  local application_name="${APPLICATION_NAME}"
  local namespace="${NAMESPACE}"
  local canary_migration_phase="${CANARY_MIGRATION_PHASE}"
  local application_namespace="${APPLICATION_NAMESPACE}"
  local profile_name="${PROFILE_NAME}"

  local feedback_annotation_key="${FEEDBACK_ANNOTATION_KEY}"
  local feedback_check_interval="${FEEDBACK_CHECK_INTERVAL}"
  local feedback_timeout="${FEEDBACK_TIMEOUT}"

  local rollout_name="${ROLLOUT_NAME}"
  local rollout_status_timeout="${ROLLOUT_STATUS_TIMEOUT}"
  local rollout_status_check_interval="${ROLLOUT_STATUS_CHECK_INTERVAL}"

  # Validate all required input parameters
  if [[ -z "$application_name" || -z "$namespace" || -z "$canary_migration_phase" || -z "$application_namespace" || \
        -z "$profile_name" || -z "$feedback_annotation_key" || -z "$feedback_check_interval" || -z "$feedback_timeout" || \
        -z "$rollout_name" || -z "$rollout_status_timeout" || -z "$rollout_status_check_interval" ]]; then
    echo -e "${RED}Error: One or more required input parameters are missing.${NC}"
    echo -e "${RED}  APPLICATION_NAME:              '${application_name}'${NC}"
    echo -e "${RED}  NAMESPACE:                     '${namespace}'${NC}"
    echo -e "${RED}  PROFILE_NAME:                  '${profile_name}'${NC}"
    echo -e "${RED}  CANARY_MIGRATION_PHASE:        '${canary_migration_phase}'${NC}"
    echo -e "${RED}  APPLICATION_NAMESPACE:         '${application_namespace}'${NC}"
    echo -e "${RED}  FEEDBACK_ANNOTATION_KEY:       '${feedback_annotation_key}'${NC}"
    echo -e "${RED}  FEEDBACK_CHECK_INTERVAL:       '${feedback_check_interval}'${NC}"
    echo -e "${RED}  FEEDBACK_TIMEOUT:              '${feedback_timeout}'${NC}"
    echo -e "${RED}  ROLLOUT_NAME:                  '${rollout_name}'${NC}"
    echo -e "${RED}  ROLLOUT_STATUS_TIMEOUT:        '${rollout_status_timeout}'${NC}"
    echo -e "${RED}  ROLLOUT_STATUS_CHECK_INTERVAL: '${rollout_status_check_interval}'${NC}"
    echo -e "${RED}Please ensure all required environment variables are set and not empty.${NC}"
    exit 2
  fi

  echo "=================================================================================================================="
  echo -e "${BLUE}🔍 Migration Workflow Context:${NC}"
  echo "   - Application Name:              ${application_name}"
  echo "   - Namespace:                     ${namespace}"
  echo "   - Project Repository Name:       ${project_repo_name}"
  echo "   - Profile Name:                  ${profile_name}"
  echo "   - Rollout Name:                  ${rollout_name}"
  echo "   - Application Namespace:         ${application_namespace}"
  echo "   - Rollout Status Check Interval: ${rollout_status_check_interval} seconds"
  echo "   - Rollout Status Timeout:        ${rollout_status_timeout}"
  echo "   - Feedback Annotation Key:       ${feedback_annotation_key}"
  echo "   - Feedback Check Interval:       ${feedback_check_interval} seconds"
  echo "   - Feedback Timeout:              ${feedback_timeout}"
  echo "   - Canary Migration Phase:        ${canary_migration_phase}"
  echo "=================================================================================================================="

  # If migration is already completed, skip the rest
  if [[ "$canary_migration_phase" == "completed" ]]; then
    echo -e "${GREEN}Migration is already completed. No further actions are required.${NC}"
    exit 0
  fi

  # Define the ordered list of phases
  local phases=("safe" "initial" "traffic" "completed")
  local start_index=-1

  # Find the current phase index
  for i in "${!phases[@]}"; do
    if [[ "${phases[$i]}" == "$canary_migration_phase" ]]; then
      start_index=$i
      break
    fi
  done

  # Check if phase is valid
  if [[ "$start_index" -eq -1 ]]; then
    echo -e "${RED}Unknown phase value in 'CANARY_MIGRATION_PHASE' environment variable: $canary_migration_phase${NC}"
    exit 2
  fi

  # Iterate through remaining phases
  local current_phase="${phases[$start_index]}"
  for ((i=start_index+1; i<${#phases[@]}; i++)); do
    local next_phase="${phases[$i]}"

    await_and_apply_feedback \
      --current-phase "$current_phase" \
      --next-phase "$next_phase" \
      --application-namespace "$application_namespace" \
      --namespace "$namespace" \
      --application-name "$application_name" \
      --profile-name "$profile_name" \
      --rollout-name "$rollout_name" \
      --rollout-status-timeout "$rollout_status_timeout" \
      --rollout-status-check-interval "$rollout_status_check_interval" \
      --feedback-annotation-key "$feedback_annotation_key" \
      --feedback-check-interval "$feedback_check_interval" \
      --feedback-timeout "$feedback_timeout" || exit $?
    
    current_phase="$next_phase"
  done

  # Final feedback after 'completed' phase
  await_and_apply_feedback \
    --current-phase "completed" \
    --next-phase "" \
    --application-namespace "$application_namespace" \
    --namespace "$namespace" \
    --application-name "$application_name" \
    --project-repo-name "$project_repo_name" \
    --profile-name "$profile_name" \
    --rollout-name "$rollout_name" \
    --rollout-status-timeout "$rollout_status_timeout" \
    --rollout-status-check-interval "$rollout_status_check_interval" \
    --feedback-annotation-key "$feedback_annotation_key" \
    --feedback-check-interval "$feedback_check_interval" \
    --feedback-timeout "$feedback_timeout" || exit $?

  echo -e "${GREEN}🎉 Migration workflow completed successfully!${NC}"
}

exec_migration_workflow
