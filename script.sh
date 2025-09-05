#!/bin/bash     

ORIGINAL_ARGS="--values values-production-api.yaml \\
            --set-string labels.commit_id=\${CIRCLE_SHA1:0:7} \\
            --set-string labels.protected_branch=\"true\" \\
            --values .k8s/values-production-api-superman.yaml \\
            --set-string labels.version=\"production\""
echo "Original args: $ORIGINAL_ARGS"

# Extract ALL --values parameters
VALUES_FROM_ARGS=()
while [[ "$ORIGINAL_ARGS" =~ --values[[:space:]]+([^[:space:]\\]+) ]]; do
  VALUES_FROM_ARGS+=("${BASH_REMATCH[1]}")
  # Remove the matched --values from the string to find the next one
  ORIGINAL_ARGS="${ORIGINAL_ARGS/${BASH_REMATCH[0]}/}"
done

echo "All extracted values files: ${VALUES_FROM_ARGS[@]}"
echo "First values file: ${VALUES_FROM_ARGS[0]}"
echo "All values files as string: ${VALUES_FROM_ARGS[*]}"

# Original processing for removing --values from args
PROCESSED_ARGS=$(echo "$ORIGINAL_ARGS" | sed -E 's/--values[[:space:]]+[^[:space:]\\]+[[:space:]]*\\?[[:space:]]*//g')

echo "Processed args (without --values): $PROCESSED_ARGS"
