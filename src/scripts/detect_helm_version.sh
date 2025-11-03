#!/bin/bash

# Script to detect which Helm version was used to create infrastructure
# 
# Usage: Set the following environment variables:
#   RELEASE_NAME - The release name to check
#   NAMESPACE - The namespace to check
#   HELM_DETECTION_DIR - Directory to store detection results (default: /tmp/helm_detection)
#
# Returns:
#   - Writes detected Helm version to ${HELM_DETECTION_DIR}/version
#   - Writes chart name to ${HELM_DETECTION_DIR}/chart_name
#   - Exit code 0 if successful or release not found (defaults to helmv3)
#   - Exit code 1 if there was an error checking Helm versions

# Constants
DETECTION_DIR="${HELM_DETECTION_DIR:-/tmp/helm_detection}"
VERSION_FILE="${DETECTION_DIR}/version"
CHART_NAME_FILE="${DETECTION_DIR}/chart_name"

# Setup dedicated directory for all temp files
function setup_temp_dir() {
  mkdir -p "${DETECTION_DIR}"
  # Clean any previous detection files
  rm -f "${DETECTION_DIR}"/* 2>/dev/null || true
}

# Write detection results to files
function write_result() {
  local version="$1"
  local chart_name="$2"
  
  echo "${version}" > "${VERSION_FILE}"
  echo "${chart_name}" > "${CHART_NAME_FILE}"
}

# Function to detect Helm v3 releases
function detect_helmv3() {
  local release_name="$1"
  local namespace="$2"
  local chart_name=""
  
  echo "Checking Helm v3..."
  set +e
  HELM_V3_OUTPUT=$(helmv3 history "${release_name}" --namespace "${namespace}" -o yaml 2>&1)
  HELM_V3_EXIT=$?
  set -e

  if [[ ${HELM_V3_EXIT} -eq 0 ]]; then
    # Extract chart name with yq if available
    if command -v yq &>/dev/null; then
      echo "${HELM_V3_OUTPUT}" | grep -v '^WARNING:' > "${DETECTION_DIR}/helm_v3_history.yaml"
      chart_name=$(yq eval 'map(select(.status == "deployed")) | .[0].chart // ""' "${DETECTION_DIR}/helm_v3_history.yaml" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')
    fi
    echo "✅ Helm v3 release detected"
    echo "📄 Manifest details ----------------------------------"
    helmv3 get manifest "${release_name}" --namespace "${namespace}"
    echo "------------------------------------------------------"
    write_result "helmv3" "${chart_name:-}"
    return 0
  elif echo "${HELM_V3_OUTPUT}" | grep -q 'release: not found'; then
    echo "❓ Helm v3 release not found"
    return 1
  else
    echo "❌ Error checking Helm v3: ${HELM_V3_OUTPUT}"
    return 2
  fi
}

# Function to detect Helm v2 releases
function detect_helmv2() {
  local release_name="$1"
  local namespace="$2"
  local chart_name=""
  
  echo "Checking Helm v2..."
  set +e
  HELM_V2_OUTPUT=$(helm history "${release_name}" -o yaml 2>&1)
  HELM_V2_EXIT=$?
  set -e

  if [[ ${HELM_V2_EXIT} -eq 0 ]]; then
    # Extract chart name with yq if available
    if command -v yq &>/dev/null; then
      echo "${HELM_V2_OUTPUT}" | grep -v '^WARNING:' > "${DETECTION_DIR}/helm_v2_history.yaml"
      chart_name=$(yq eval 'map(select(.status == "DEPLOYED")) | .[0].chart // ""' "${DETECTION_DIR}/helm_v2_history.yaml" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')
    fi
    echo "✅ Helm v2 release detected"
    echo "📄 Manifest details ----------------------------------"
    helm get manifest "${release_name}"
    echo "------------------------------------------------------"
    write_result "helmv2" "${chart_name:-}"
    return 0
  elif echo "${HELM_V2_OUTPUT}" | grep -q 'not found' || echo "${HELM_V2_OUTPUT}" | grep -q 'release: ".*" not found'; then
    echo "❓ Helm v2 release not found"
    return 1
  else
    echo "❌ Error checking Helm v2: ${HELM_V2_OUTPUT}"
    return 2
  fi
}

# Print detection results
function print_results() {
  local version="$1"
  local chart="$2"
  local message="$3"
  
  echo "------------------------------------------------------"
  echo "📊 Results: ${message:-}"
  echo "   - Helm Version: ${version}"
  echo "   - Chart Name: ${chart:-<empty>}"
}

# Main detection function
function detect_helm_version() {
  local release_name="$1"
  local namespace="$2"

  echo "🔍 Detecting Helm version for release: ${release_name} in namespace: ${namespace}"
  echo "------------------------------------------------------"

  # Setup temp directory
  setup_temp_dir

  # Try Helm v3
  if detect_helmv3 "${release_name}" "${namespace}"; then
    # Success - Helm v3 release found
    print_results "helmv3" "$(cat ${CHART_NAME_FILE})" "Helm v3 release found"
    return 0
  fi
  
  # Check return code from detect_helmv3
  local v3_result=$?
  if [[ ${v3_result} -eq 2 ]]; then
    # Error occurred with Helm v3 check that wasn't "not found"
    echo "❌ Error occurred checking Helm v3"
    return 1  # Exit with error
  fi
  
  # If we're here, Helm v3 returned 1 (release not found), try Helm v2
  echo "Trying Helm v2 since no v3 release found..."
  
  if detect_helmv2 "${release_name}" "${namespace}"; then
    # Success - Helm v2 release found
    print_results "helmv2" "$(cat ${CHART_NAME_FILE})" "Helm v2 release found"
    return 0
  fi
  
  # Check return code from detect_helmv2
  local v2_result=$?
  if [[ ${v2_result} -eq 2 ]]; then
    # Error occurred with Helm v2 check that wasn't "not found"
    echo "❌ Error occurred checking Helm v2"
    return 1  # Exit with error
  fi
  
  # If we're here, both Helm v2 and v3 returned "release not found"
  echo "No Helm release found with either v2 or v3 - defaulting to helmv3 with empty chart"
  write_result "helmv3" ""
  print_results "helmv3" "" "No Helm release found, defaulting to helmv3"
  return 0
}

function main() {
  local release_name="${RELEASE_NAME}"
  local namespace="${NAMESPACE}"

  # Check if we have the required environment variables
  if [[ -z "$release_name" ]] || [[ -z "$namespace" ]]; then
    echo "Error: Missing required environment variables"
    echo "Please set the following environment variables:"
    echo "     RELEASE_NAME - The release name to check"
    echo "     NAMESPACE - The namespace to check"
    echo "     HELM_DETECTION_DIR - Directory to store detection results (default: /tmp/helm_detection)"
    exit 1
  fi

  detect_helm_version "$release_name" "$namespace"
  exit $?
}

main
