#!/bin/bash

if [[ -z "${ROLLOUT_STATUS_COMMON_SCRIPT:-}" ]]; then
  echo "Error: ROLLOUT_STATUS_COMMON_SCRIPT is empty" >&2
  exit 2
fi

source <(echo "$ROLLOUT_STATUS_COMMON_SCRIPT")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

############################################################
# await_and_apply_feedback:
# Waits for user feedback on the next migration phase via an ArgoCD Application annotation.
#
# This function:
#   - Prompts the user (via instructions in the terminal) to add an annotation to the ArgoCD Application.
#   - Periodically checks for the annotation value ("proceed" or "rollback").
#   - If "proceed": deletes the annotation, advances the migration phase, and continues the workflow.
#   - If "rollback": deletes the annotation, rolls back the migration, and exits with an error.
#   - Retries until a valid value is found or a timeout occurs.
#
# Arguments:
#   $1 - The next migration phase to set if proceeding.
#   $2 - The namespace of the ArgoCD Application.
#   $3 - The name of the ArgoCD Application.
############################################################
function await_and_apply_feedback() {

  # Export variables so they are available in the environment of the subshell
  # executed by 'timeout'. This is necessary because 'timeout' runs the command
  # in a new bash process, and only exported variables are accessible there.
  export next_phase="$1"
  export namespace="$2"
  export application_name="$3"
  export annotation_key="${FEEDBACK_ANNOTATION_KEY:-migration.argocd.io/approval-next-phase}"
  export feedback_check_interval="${FEEDBACK_CHECK_INTERVAL:-10}"

  function handle_feedback_decision() {

    function delete_annotation() {
      if ! kubectl annotate applications -n "${namespace}" "${application_name}" "${annotation_key}-" --overwrite; then
        echo -e "${RED}❌ Failed to delete annotation ${annotation_key}${NC}"
        exit 1
      fi
      echo -e "${CYAN}🗑️ Deleted annotation ${annotation_key} for future reuse${NC}"
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
      if [ $result -ne 0 ]; then
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
      status=$(kubectl get applications -n "${namespace}" "${application_name}" -o jsonpath="{.metadata.annotations.${annotation_key//./\\.}}" 2>/dev/null)
      if [[ $? -ne 0 ]]; then
        sleep $feedback_check_interval
        continue
      fi
      if [[ -z "$status" ]]; then
        sleep $feedback_check_interval
        continue
      fi
      echo "Found feedback annotation with value: $status"
      case "$status" in
        "proceed")
          echo -e "${GREEN}✅ User feedback is to PROCEED with deployment${NC}"
          delete_annotation
          set_next_phase
          exec_rollout_status  
          exit $?
          ;;
        "rollback")
          echo -e "${CYAN}⚠️ User feedback is to ROLLBACK deployment${NC}"
          delete_annotation
          rollback_migration
          exec_rollout_status
          # We want to exit with an error code to indicate rollback
          exit 1
          ;;
        *)
          echo -e "${CYAN}⚠️ Unknown feedback value: '$status', will retry in $feedback_check_interval seconds${NC}"
          sleep $feedback_check_interval
          ;;
      esac
    done
  }

  local feedback_timeout="${FEEDBACK_TIMEOUT:-30m}"

  echo "=================================================================================================================="
  echo -e "${BLUE}ℹ️  Please use the ArgoCD UI to add the following annotation to the application:${NC}"
  echo "    Key:   ${annotation_key}"
  echo "    Value: proceed   (to continue)  OR  rollback   (to rollback)"
  echo "   (In the ArgoCD UI, go to the Application, click 'App Details', then 'Edit Metadata', and add the annotation.)"
  echo "=================================================================================================================="
  echo -e "${GREEN}📝 Next step if you proceed: ${next_phase}${NC}"
  echo "=================================================================================================================="

  set +e

  timeout "${feedback_timeout}" bash -o pipefail -c "$(declare -f handle_feedback_decision exec_rollout_status); handle_feedback_decision"
  timeout_result=$?

  if [[ $timeout_result -eq 124 ]]; then
    echo -e "${RED}⏰ Timeout reached while waiting for user feedback.${NC}"
    return 1
  else
    return $timeout_result
  fi
}

############################################################
# exec_migration_workflow: Drives the migration workflow
############################################################
function exec_migration_workflow() {
  local application_name namespace rollout_name migration_phase_file_name

  application_name="${APPLICATION_NAME}"
  namespace="${NAMESPACE}"
  rollout_name="${ROLLOUT_NAME}"
  migration_phase_file_name="${CURRENT_MIGRATION_PHASE_FILE}"
  application_namespace=${APPLICATION_NAMESPACE:-argocd}

  if [[ -z "$application_name" ]] || [[ -z "$namespace" ]] || [[ -z "$rollout_name" ]] || [[ -z "$migration_phase_file_name" ]]; then
    echo -e "${RED}Error: Missing required variables for ArgoCD application migration.${NC}"
    echo -e "${RED}  application_name:        '${application_name}'${NC}"
    echo -e "${RED}  namespace:               '${namespace}'${NC}"
    echo -e "${RED}  rollout_name:            '${rollout_name}'${NC}"
    echo -e "${RED}  migration_phase_file_name:'${migration_phase_file_name}'${NC}"
    echo -e "${RED}Please ensure all required environment variables are set and not empty.${NC}"
    exit 2
  fi

  if [[ ! -f "$migration_phase_file_name" ]]; then
    echo -e "${RED}Error: Migration phase file '$migration_phase_file_name' not found.${NC}"
    exit 2
  fi

  echo "=================================================================================================================="
  echo -e "${BLUE}🔍 Migration Workflow Context:${NC}"
  echo "   - Application Name:        ${application_name}"
  echo "   - Namespace:               ${namespace}"
  echo "   - Rollout Name:            ${rollout_name}"
  echo "   - Migration Phase File:    ${migration_phase_file_name}"
  echo "   - Application Namespace:   ${application_namespace}"
  echo "=================================================================================================================="

  local phase_value
  phase_value=$(cat "$migration_phase_file_name" | tr -d '\n')

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
    echo -e "${RED}Unknown phase value in $migration_phase_file_name: $phase_value${NC}"
    exit 2
  fi

  # Iterate through remaining phases
  for ((i=start_index+1; i<${#phases[@]}; i++)); do
    if ! await_and_apply_feedback "${phases[$i]}" "$application_namespace" "$application_name"; then
      echo -e "${RED}❌ Migration workflow aborted due to feedback or error.${NC}"
      exit 1
    fi
  done

  echo -e "${GREEN}🎉 Migration workflow completed successfully!${NC}"
}

exec_migration_workflow
