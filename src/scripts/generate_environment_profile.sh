#!/usr/bin/env bash

# generate_environment_profile.sh
# Generates the environment profile YAML for Argo Rollouts deployment,
# mapping ingress controller class and profile to the correct controller type.
# Expects the following environment variables:
#   PROFILE_NAME: The deployment profile (e.g., staging, production)
#   VALUES_FILE_NAME: Path to the Helm values YAML file
#   OUTPUT_PROFILE_FILE_NAME: Path where the resulting YAML will be written

# Constants
readonly SUPPORTED_PROFILES=("staging" "production")

# Global variable for ingress controller type
INGRESS_CONTROLLER_TYPE=""

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

# Logging functions
function log_info() {
  echo "ℹ️  $*" >&2
}

function log_error() {
  echo "❌ Error: $*" >&2
}

function log_success() {
  echo "✅ $*" >&2
}

# Prerequisite validation function
function validate_prerequisites() {
  if ! yq --version >/dev/null 2>&1; then
    log_error "yq command not found. Please install yq to continue"
    return 1
  fi
}

# Validation functions
function validate_environment_variables() {
  local missing_vars=()

  [[ -z "${PROFILE_NAME:-}" ]] && missing_vars+=("PROFILE_NAME")
  [[ -z "${VALUES_FILE_NAME:-}" ]] && missing_vars+=("VALUES_FILE_NAME")
  [[ -z "${OUTPUT_PROFILE_FILE_NAME:-}" ]] && missing_vars+=("OUTPUT_PROFILE_FILE_NAME")

  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    return 1
  fi
}

function validate_profile_name() {
  local profile="$1"
  local is_valid=false

  for supported_profile in "${SUPPORTED_PROFILES[@]}"; do
    if [[ "$profile" == "$supported_profile" ]]; then
      is_valid=true
      break
    fi
  done

  if [[ "$is_valid" == false ]]; then
    log_error "Unsupported profile '$profile'. Supported profiles: ${SUPPORTED_PROFILES[*]}"
    return 1
  fi
}

function validate_values_file() {
  local values_file="$1"

  if [[ ! -f "$values_file" ]]; then
    log_error "Values file not found: $values_file"
    return 1
  fi

  # Validate that the file is valid YAML
  if ! yq eval '.' "$values_file" >/dev/null 2>&1; then
    log_error "Values file contains invalid YAML: $values_file"
    return 1
  fi
}

# Check functions with improved error handling
function user_defined_steps_exist() {
  local values_file="$1"
  local steps_count

  steps_count=$(yq '.deployment.canary.steps | length' "$values_file" 2>/dev/null || echo "0")
  [[ "$steps_count" -gt 0 ]]
}

function user_defined_default_steps_enabled() {
  local values_file="$1"
  local enabled_value

  enabled_value=$(yq '.deployment.canary.defaultSteps.enabled // ""' "$values_file" 2>/dev/null || echo "")
  [[ -n "$enabled_value" ]]
}

# YAML generation functions with better formatting
function get_default_steps_yaml() {
  local profile_name="$1"

  case "$profile_name" in
    production)
      cat <<'EOF'
- setWeight: 25
- pause: {}
- setWeight: 60
- pause: {}
- setWeight: 100
EOF
      ;;
    *)
      cat <<'EOF'
- setWeight: 100
EOF
      ;;
  esac
}

function get_default_steps_enabled_yaml() {
  local profile_name="$1"

  case "$profile_name" in
    production)
      cat <<'EOF'
defaultSteps:
  enabled: true
  initialWorkload:
    scale: 10
  initialTraffic:
    weight: 5
EOF
      ;;
    *)
      cat <<'EOF'
defaultSteps:
  enabled: false
EOF
      ;;
  esac
}

function compute_ingress_controller_type() {
  local profile_name="$1"
  local values_file="$2"

  local YQ_EXPR='select(.ingress.enabled == true) | .ingress.annotations."kubernetes.io/ingress.class" // ""'

  local ingress_controller_class
  ingress_controller_class=$(yq "$YQ_EXPR" "$values_file")

  if [[ -z "$ingress_controller_class" || "$ingress_controller_class" == "null" ]]; then
    log_info "No ingress class found in values file. Using default for profile '$profile_name'"
    INGRESS_CONTROLLER_TYPE="${DEFAULT_INGRESS_CONTROLLER_TYPE[$profile_name]}"
    if [[ -z "$INGRESS_CONTROLLER_TYPE" ]]; then
      log_error "Unsupported profile name value: $profile_name"
      exit 1
    fi
  else
    INGRESS_CONTROLLER_TYPE="${INGRESS_CONTROLLER_TYPE_MAP[$profile_name:$ingress_controller_class]}"
    log_info "Found ingress class '$ingress_controller_class' in values file. Using mapped value for profile '$profile_name'"
    if [[ -z "$INGRESS_CONTROLLER_TYPE" ]]; then
      log_error "Invalid INGRESS_CONTROLLER_CLASS '$ingress_controller_class' for profile '$profile_name'"
      exit 1
    fi
  fi
}

function generate_profile_yaml() {
  local output_file="$1"

  {
    echo "profileName: $PROFILE_NAME"
    echo "deployment:"
    echo "  canary:"
    echo "    traffic:"
    echo "      ingressControllerType: $INGRESS_CONTROLLER_TYPE"

    # Add defaultSteps.enabled only if not defined by user
    if ! user_defined_default_steps_enabled "$VALUES_FILE_NAME"; then
      get_default_steps_enabled_yaml "$PROFILE_NAME" | sed 's/^/    /'
    fi

    # Add steps only if not defined by user
    if ! user_defined_steps_exist "$VALUES_FILE_NAME"; then
      echo "    steps:"
      get_default_steps_yaml "$PROFILE_NAME" | sed 's/^/      /'
    fi
  } > "$output_file"
}

main() {
  # Validate prerequisites first
  validate_prerequisites || exit 1

  # Validate inputs
  validate_environment_variables || exit 1
  validate_profile_name "$PROFILE_NAME" || exit 1
  validate_values_file "$VALUES_FILE_NAME" || exit 1

  # Compute ingress controller type
  if ! compute_ingress_controller_type "$PROFILE_NAME" "$VALUES_FILE_NAME"; then
    exit 1
  fi

  # Generate profile YAML
  if ! generate_profile_yaml "$OUTPUT_PROFILE_FILE_NAME"; then
    log_error "Failed to generate profile YAML"
    exit 1
  fi

  log_success "Environment profile written to $OUTPUT_PROFILE_FILE_NAME"

  echo "----- Environment profile content -----"
  cat "$OUTPUT_PROFILE_FILE_NAME"
  echo "---------------------------------------"
}

# Run the main function
main
