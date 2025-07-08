#!/bin/bash -eo pipefail

        echo "Polling for user feedback annotation 'canary.tiendanube.com/next-migration-step'..."
        MAX_ATTEMPTS=8640  # 24 hours (10 seconds per attempt)
        SLEEP_SECONDS=10
        ATTEMPTS=0
        ANNOTATION_KEY="canary.tiendanube.com/next-migration-step"
        APP_NAME="${HELM_RELEASE_NAME}"
        NAMESPACE="argocd"
        # Function to delete the annotation and print a message
        delete_annotation() {
          kubectl annotate application -n "${NAMESPACE}" "${APP_NAME}" \
            "${ANNOTATION_KEY}-" --overwrite
          echo "🗑️ Deleted annotation for future reuse"
        }
        while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
          ATTEMPTS=$((ATTEMPTS+1))
          if [ $((ATTEMPTS % 60)) -eq 0 ]; then
            echo "Polling for $(($ATTEMPTS / 60)) minutes..."
          fi
          STATUS=$(kubectl get application -n "${NAMESPACE}" "${APP_NAME}" \
            -o jsonpath='{.metadata.annotations.'${ANNOTATION_KEY//\./\\.}'}' 2>/dev/null)
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
              break
              ;;
            "rollback")
              echo "⚠️ User feedback is to ROLLBACK deployment"
              delete_annotation
              echo "Rollback requested by user via annotation"
              exit 1
              ;;
            *)
              echo "⚠️ Unknown feedback value: '$STATUS', will retry in $SLEEP_SECONDS seconds"
              sleep $SLEEP_SECONDS
              ;;
          esac
        done
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
          echo "❌ Timed out waiting for user feedback annotation after 24 hours"
          echo "Please manually check the deployment status"
          exit 1
        fi

