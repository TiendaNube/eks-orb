#!/bin/bash

############################################################
# ask_feedback: Waits for user feedback via ArgoCD annotation
# Polls a specific annotation on an ArgoCD Application to determine
# if the user wants to proceed or rollback the deployment. Times out
# after a configurable period if no feedback is received.
############################################################
ask_feedback() {
  ANNOTATION_KEY="${ANNOTATION_KEY:-feedback.argocd.io/user-action}"
  APP_NAME="${APP_NAME}"
  NAMESPACE="${NAMESPACE}"
  MIGRATION_PHASE="${MIGRATION_PHASE:-}"
  TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"
  CHECK_INTERVAL="${CHECK_INTERVAL:-10}"

  echo "------------------------------------------------------"
  echo "Waiting for user feedback on ArgoCD application deployment..."
  echo "------------------------------------------------------"
  echo "Polling for user feedback annotation '${ANNOTATION_KEY}'..."

  MAX_ATTEMPTS=$((TIMEOUT_MINUTES * 60 / CHECK_INTERVAL))
  SLEEP_SECONDS=$CHECK_INTERVAL
  ATTEMPTS=0

  delete_annotation() {
    kubectl annotate application -n "${NAMESPACE}" "${APP_NAME}" "${ANNOTATION_KEY}-" --overwrite
    echo "🗑️ Deleted annotation for future reuse"
  }

  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    ATTEMPTS=$((ATTEMPTS+1))
    if [ $((ATTEMPTS % 60)) -eq 0 ]; then
      echo "Polling for $((ATTEMPTS * SLEEP_SECONDS / 60)) minutes..."
    fi
    STATUS=$(kubectl get application -n "${NAMESPACE}" "${APP_NAME}" -o jsonpath="{.metadata.annotations.${ANNOTATION_KEY//./\\.}}" 2>/dev/null)
    if [ $? -ne 0 ]; then
      echo "Error retrieving annotation, will retry in $SLEEP_SECONDS seconds"
      sleep $SLEEP_SECONDS
      continue
    fi
    if [ -z "$STATUS" ]; then
      echo "No feedback annotation found yet, will retry in $SLEEP_SECONDS seconds" >&2
      sleep $SLEEP_SECONDS
      continue
    fi
    echo "Found feedback annotation with value: $STATUS"
    case "$STATUS" in
      "proceed")
        echo "✅ User feedback is to PROCEED with deployment"
        delete_annotation
        return 0
        ;;
      "rollback")
        echo "⚠️ User feedback is to ROLLBACK deployment"
        delete_annotation
        if [ -n "${MIGRATION_PHASE}" ]; then
          echo "Setting canaryMigrationPhaseOverride to 'safe' for rollback"
        fi
        echo "Rollback requested by user via annotation"
        return 1
        ;;
      *)
        echo "⚠️ Unknown feedback value: '$STATUS', will retry in $SLEEP_SECONDS seconds"
        sleep $SLEEP_SECONDS
        ;;
    esac
  done

  if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
    echo "❌ Timed out waiting for user feedback annotation after $TIMEOUT_MINUTES minutes"
    echo "Please manually check the deployment status"
    return 1
  fi
}

############################################################
# argo_rollout_status: Monitors the status of an Argo Rollout
# Periodically checks the rollout status using 'kubectl argo rollouts'.
# Exits with success if rollout is Healthy/Completed, or with failure
# if Degraded/Error/Aborted. Times out after a configurable period.
############################################################
argo_rollout_status() {
  ROLLOUT_NAME="${ROLLOUT_NAME}"
  NAMESPACE="${NAMESPACE}"
  TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1m}"
  CHECK_INTERVAL="${CHECK_INTERVAL:-10}"

  set +e
  timeout "${TIMEOUT_SECONDS}" bash -o pipefail -c '
    i=1
    while true; do
      echo "========================================================"
      echo "🔍 Checking release status (attempt $i)..."
      output=$(kubectl argo rollouts get rollout "${ROLLOUT_NAME}" --namespace "${NAMESPACE}")
      echo "$output"
      status=$(echo "$output" | grep "^Status:" | awk "{print \$3}")
      case "$status" in
        Healthy|Completed)
          echo "✅ Rollout is $status."
          exit 0
          ;;
        Degraded|Error|Aborted)
          echo "❌ Release status is $status. Exiting with failure."
          exit 1
          ;;
        Progressing|Paused)
          echo "⏳ Release status is $status. Waiting..."
          ;;
        *)
          echo "❓ Unknown status: $status. Waiting..."
          ;;
      esac
      i=$((i+1))
      sleep "${CHECK_INTERVAL}"
    done
  '
  TIMEOUT_RESULT=$?
  if [[ $TIMEOUT_RESULT -eq 124 ]]; then
    echo "⏰ Timeout reached while checking release status."
    exit 0
  else
    exit $TIMEOUT_RESULT
  fi
}

# Check if we have the required environment variables
if [ -z "$RELEASE_NAME" ] || [ -z "$NAMESPACE" ] || [ -z "$CURRENT_MIGRATION_PHASE_FILE" ]; then
  echo "Error: Missing required environment variables"
  echo "Please set the following environment variables:"
  echo "     RELEASE_NAME - The release name"
  echo "     NAMESPACE - The namespace"
  echo "     CURRENT_MIGRATION_PHASE_FILE - File path with the migration phase value"
  exit 1
fi

# Executes 'echo Hola Mundo' a number of times depending on the value read from the CURRENT_MIGRATION_PHASE_FILE file.
# - safe:      3 times
# - initial:   2 times
# - traffic:   1 time
# - completed: 0 times
if [ -n "$CURRENT_MIGRATION_PHASE_FILE" ] && [ -f "$CURRENT_MIGRATION_PHASE_FILE" ]; then
  PHASE_VALUE=$(cat "$CURRENT_MIGRATION_PHASE_FILE" | tr -d '\n')
  case "$PHASE_VALUE" in
    safe)
      for i in {1..3}; do echo "Hola Mundo"; done
      ;;
    initial)
      for i in {1..2}; do echo "Hola Mundo"; done
      ;;
    traffic)
      echo "Hola Mundo"
      ;;
    completed)
      # Do nothing
      ;;
    *)
      echo "Unknown phase value in $CURRENT_MIGRATION_PHASE_FILE: $PHASE_VALUE"
      ;;
  esac
fi