#!/usr/bin/env bash

# generate_environment_profile.sh
# Generates the environment profile YAML for Argo Rollouts deployment,
# mapping ingress controller class and profile to the correct controller type.
# Expects the following environment variables:
#   PROFILE_NAME: The deployment profile (e.g., staging, production)
#   VALUES_FILE_NAME: Path to the Helm values YAML file
#   OUTPUT_PROFILE_FILE_NAME: Path where the resulting YAML will be written

if [[ -z "$PROFILE_NAME" || -z "$VALUES_FILE_NAME" || -z "$OUTPUT_PROFILE_FILE_NAME" ]]; then
  echo "❌ Error: PROFILE_NAME, VALUES_FILE_NAME, and OUTPUT_PROFILE_FILE_NAME environment variables are required"
  exit 1
fi

# Default controller type per profile
declare -A DEFAULT_INGRESS_CONTROLLER_TYPE=(
  [staging]="nginx"
  [production]="aws-alb"
)

# Unified mapping: key is "${PROFILE_NAME}:${INGRESS_CLASS}"
declare -A INGRESS_CONTROLLER_TYPE_MAP=(
  [staging:alb]="aws-alb"
  [staging:nginx]="nginx"
  [staging:nginx-internal]="nginx"
  [staging:nginx-tcp-internal]="nginx"
  [production:alb]="aws-alb"
  [production:nginx]="nginx"
)

# Default value for INGRESS_CONTROLLER_TYPE
INGRESS_CONTROLLER_TYPE=""

function compute_ingress_controller_type() {
  local profile_name="$1"
  local values_file="$2"

  local YQ_EXPR='select(.ingress.enabled == true) | .ingress.annotations."kubernetes.io/ingress.class" // ""'

  local ingress_controller_class
  ingress_controller_class=$(yq "$YQ_EXPR" "$values_file")

  if [[ -z "$ingress_controller_class" || "$ingress_controller_class" == "null" ]]; then
    echo "ℹ️  No ingress class found in values file. Using default for profile '$profile_name'"
    INGRESS_CONTROLLER_TYPE="${DEFAULT_INGRESS_CONTROLLER_TYPE[$profile_name]}"
    if [[ -z "$INGRESS_CONTROLLER_TYPE" ]]; then
      echo "❌ Error: Unsupported profile name value: $profile_name"
      exit 1
    fi
  else
    INGRESS_CONTROLLER_TYPE="${INGRESS_CONTROLLER_TYPE_MAP[$profile_name:$ingress_controller_class]}"
    echo "ℹ️  Found ingress class '$ingress_controller_class' in values file. Using mapped value for profile '$profile_name'"
    if [[ -z "$INGRESS_CONTROLLER_TYPE" ]]; then
      echo "❌ Error: Invalid INGRESS_CONTROLLER_CLASS '$ingress_controller_class' for profile '$profile_name'"
      exit 1
    fi
  fi
}

compute_ingress_controller_type "$PROFILE_NAME" "$VALUES_FILE_NAME"

cat <<EOF > "$OUTPUT_PROFILE_FILE_NAME"
profileName: $PROFILE_NAME
deployment:
  canary:
    traffic:
      ingressControllerType: $INGRESS_CONTROLLER_TYPE
EOF

echo "✅ Environment profile written to $OUTPUT_PROFILE_FILE_NAME"

echo "----- Environment profile content -----"
cat "$OUTPUT_PROFILE_FILE_NAME"
echo "---------------------------------------"
