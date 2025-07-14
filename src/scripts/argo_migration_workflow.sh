#!/bin/bash

eval "$ROLLOUT_STATUS_COMMON_SCRIPT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

############################################################
# ask_feedback: Waits for user feedback via ArgoCD annotation
############################################################
ask_feedback() {

  # Export variables so they are available in the environment of the subshell
  # executed by 'timeout'. This is necessary because 'timeout' runs the command
  # in a new bash process, and only exported variables are accessible there.
  export next_phase="$1"
  export namespace="$2"
  export application_name="$3"
  export annotation_key="${FEEDBACK_ANNOTATION_KEY:-migration.argocd.io/approval-next-phase}"
  export feedback_check_interval="${FEEDBACK_CHECK_INTERVAL:-10}"

  delete_annotation() {
    kubectl annotate application -n "${namespace}" "${application_name}" "${annotation_key}-" --overwrite
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to delete annotation ${annotation_key}${NC}"
      exit 1
    fi
    echo -e "${YELLOW}🗑️ Deleted annotation ${annotation_key} for future reuse${NC}"
  }

  prepare_argocd_cli() {
    kubectl config set-context --current --namespace="${namespace}"
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to set kubectl context to namespace '${namespace}'${NC}"
      exit 1
    fi
    argocd login cd.argoproj.io --core
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to login to ArgoCD CLI in namespace '${namespace}'${NC}"
      exit 1
    fi
    echo -e "${GREEN}✅ ArgoCD CLI prepared for namespace '${namespace}'.${NC}"
  }

  rollback_prepare_argocd_cli() {
    kubectl config set-context --current --namespace="default"
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to reset kubectl context to default namespace.${NC}"
      exit 1
    fi 
  }

  set_next_phase() {
    prepare_argocd_cli
    argocd app set "${application_name}" --helm-set canaryMigrationPhaseOverride="${next_phase}"
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to set next phase to '${next_phase}'${NC}"
      exit 1
    fi
    rollback_prepare_argocd_cli
    echo -e "${GREEN}✅ Next phase set to '${next_phase}'${NC}"
  }

  rollback_migration() {
    prepare_argocd_cli
    argocd app set "${application_name}" --helm-set canaryMigrationPhaseOverride=safe
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Failed to rollback migration to safe phase${NC}"
      exit 1
    fi
    rollback_prepare_argocd_cli
    echo -e "${GREEN}✅ Migration rolled back to safe phase${NC}"
  }

  wait_for_feedback() {
    while true; do
      status=$(kubectl get application -n "${namespace}" "${application_name}" -o jsonpath="{.metadata.annotations.${annotation_key//./\\.}}" 2>/dev/null)
      if [ $? -ne 0 ]; then
        sleep $feedback_check_interval
        continue
      fi
      if [ -z "$status" ]; then
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
          exit 0
          ;;
        "rollback")
          echo -e "${YELLOW}⚠️ User feedback is to ROLLBACK deployment${NC}"
          delete_annotation
          rollback_migration
          exec_rollout_status
          exit 1
          ;;
        *)
          echo -e "${YELLOW}⚠️ Unknown feedback value: '$status', will retry in $feedback_check_interval seconds${NC}"
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

  timeout "${feedback_timeout}" bash -o pipefail -c "$(declare -f wait_for_feedback delete_annotation rollback_migration set_next_phase rollback_prepare_argocd_cli prepare_argocd_cli); wait_for_feedback"
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
exec_migration_workflow() {
  local application_name namespace rollout_name migration_phase_file_name

  application_name=$(eval echo "${APPLICATION_NAME}")
  namespace=$(eval echo "${NAMESPACE}")
  rollout_name=$(eval echo "${ROLLOUT_NAME}")
  migration_phase_file_name="${CURRENT_MIGRATION_PHASE_FILE}"
  application_namespace=${APPLICATION_NAMESPACE:-argocd}

  if [ -z "$application_name" ] || [ -z "$namespace" ] || [ -z "$rollout_name" ] || [ -z "$migration_phase_file_name" ]; then
    echo -e "${RED}Error: Missing required variables for ArgoCD application migration.${NC}"
    exit 2
  fi

  if [ ! -f "$migration_phase_file_name" ]; then
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
  if [ "$start_index" -eq -1 ]; then
    echo -e "${RED}Unknown phase value in $migration_phase_file_name: $phase_value${NC}"
    exit 2
  fi

  # Iterate through remaining phases
  for ((i=start_index+1; i<${#phases[@]}; i++)); do
    ask_feedback "${phases[$i]}" "$application_namespace" "$application_name" || exit 1
  done

  echo -e "${GREEN}🎉 Migration workflow completed successfully!${NC}"
}

exec_migration_workflow
