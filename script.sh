#!/bin/bash     

ORIGINAL_ARGS="--values values-production-api.yaml \\
            --set-string labels.commit_id=\${CIRCLE_SHA1:0:7} \\
            --set-string labels.protected_branch=\"true\" \\
            --set-string labels.version=\"production\""
echo "Original args: $ORIGINAL_ARGS"

# Extract --values parameter
VALUES_FROM_ARGS=""
if [[ "$ORIGINAL_ARGS" =~ --values[[:space:]]+([^[:space:]\\]+) ]]; then
  VALUES_FROM_ARGS="${BASH_REMATCH[1]}"
  echo "Extracted values file: $VALUES_FROM_ARGS"
fi

# Remove --values parameter from args
PROCESSED_ARGS=$(echo "$ORIGINAL_ARGS" | sed -E 's/--values[[:space:]]+[^[:space:]\\]+[[:space:]]*\\?[[:space:]]*//g')

# Clean up any double spaces or trailing backslashes
PROCESSED_ARGS=$(echo "$ORIGINAL_ARGS" | sed -E 's/--values[[:space:]]+[^[:space:]\\]+[[:space:]]*\\?[[:space:]]*//g' | sed -E 's/[[:space:]]+/ /g' | sed -E 's/[[:space:]]*\\[[:space:]]*$//g' | sed -E 's/^[[:space:]]*//g')

echo "Processed args (without --values): $PROCESSED_ARGS"
echo "Values file extracted: $VALUES_FROM_ARGS"