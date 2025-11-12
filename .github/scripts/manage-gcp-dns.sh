#!/bin/bash
set -euo pipefail

# GCP DNS Management Script
# Adds or removes DNS records in GCP Cloud DNS based on BBL state

ACTION="${ACTION:-}"
BBL_STATE_DIR="${BBL_STATE_DIR:-}"
GCP_DNS_SERVICE_ACCOUNT_KEY="${GCP_DNS_SERVICE_ACCOUNT_KEY:-}"
GCP_DNS_ZONE_NAME="${GCP_DNS_ZONE_NAME:-}"
GCP_DNS_RECORD_SET_NAME="${GCP_DNS_RECORD_SET_NAME:-}"
GCP_DNS_RECORD_TTL="${GCP_DNS_RECORD_TTL:-300}"
CHECK_DNS="${CHECK_DNS:-false}"
MAX_SUCCESS_COUNT="${MAX_SUCCESS_COUNT:-3}"

# Validate required parameters
if [[ -z "${ACTION}" || -z "${BBL_STATE_DIR}" || -z "${GCP_DNS_SERVICE_ACCOUNT_KEY}" ||
  -z "${GCP_DNS_ZONE_NAME}" || -z "${GCP_DNS_RECORD_SET_NAME}" ]]; then
  echo "ERROR: Missing required parameters"
  echo "Required: ACTION, BBL_STATE_DIR, GCP_DNS_SERVICE_ACCOUNT_KEY, GCP_DNS_ZONE_NAME, GCP_DNS_RECORD_SET_NAME"
  exit 1
fi

check_dns() {
  local domain="${1}"
  local count=0
  local max_successes="${MAX_SUCCESS_COUNT}"

  echo "Verifying DNS for domain: ${domain}"

  while [[ "${count}" -lt "${max_successes}" ]]; do
    if host "${domain}"; then
      count=$((count + 1))
      echo "DNS check ${count}/${max_successes} succeeded"
    else
      count=0
      echo "DNS check failed, resetting counter"
    fi
    sleep 5
  done

  echo "DNS verification completed successfully"
}

main() {
  # Write service account key to temporary file
  GCP_SERVICE_ACCOUNT_KEY_PATH="/tmp/gcp_dns_service_account_${RANDOM}.json"
  echo "${GCP_DNS_SERVICE_ACCOUNT_KEY}" >"${GCP_SERVICE_ACCOUNT_KEY_PATH}"

  # Trap to ensure cleanup
  trap 'rm -f "${GCP_SERVICE_ACCOUNT_KEY_PATH}"' EXIT

  # Authenticate with gcloud
  GCP_DNS_SERVICE_ACCOUNT_EMAIL=$(jq -r .client_email "${GCP_SERVICE_ACCOUNT_KEY_PATH}")
  GCP_DNS_PROJECT_ID=$(jq -r .project_id "${GCP_SERVICE_ACCOUNT_KEY_PATH}")

  echo "Authenticating with GCP as ${GCP_DNS_SERVICE_ACCOUNT_EMAIL}"
  gcloud auth activate-service-account "${GCP_DNS_SERVICE_ACCOUNT_EMAIL}" \
    --key-file="${GCP_SERVICE_ACCOUNT_KEY_PATH}" --quiet

  # Get DNS servers from BBL state
  dns_servers=()
  if [[ -d "${BBL_STATE_DIR}" ]]; then
    echo "Extracting DNS servers from BBL state..."

    while IFS= read -r dns_server; do
      dns_servers+=("${dns_server}")
    done < <(bbl --state-dir "${BBL_STATE_DIR}" lbs --json | jq -r '.cf_system_domain_dns_servers[]')
  else
    echo "ERROR: BBL state directory not found: ${BBL_STATE_DIR}"
    exit 1
  fi

  if [[ ${#dns_servers[@]} -eq 0 && "${ACTION}" == "add" ]]; then
    echo "ERROR: No DNS servers found in BBL state"
    exit 1
  fi

  echo "Found ${#dns_servers[@]} DNS server(s): ${dns_servers[*]}"

  # Check for existing DNS entry
  zone_info=$(gcloud --project="${GCP_DNS_PROJECT_ID}" \
    dns record-sets list \
    -z "${GCP_DNS_ZONE_NAME}" \
    --filter "${GCP_DNS_RECORD_SET_NAME}" \
    --format=json 2>/dev/null || echo "[]")

  if [[ "${ACTION}" == "remove" && "${zone_info}" == "[]" ]]; then
    echo "DNS entry for \"${GCP_DNS_RECORD_SET_NAME}\" not found in zone \"${GCP_DNS_ZONE_NAME}\""
    echo "Nothing to remove"
    exit 0
  fi

  # Start DNS transaction
  echo "Starting DNS transaction..."
  gcloud --project="${GCP_DNS_PROJECT_ID}" \
    dns record-sets transaction start \
    -z "${GCP_DNS_ZONE_NAME}"

  # Trap to abort transaction on error
  trap 'gcloud --project="${GCP_DNS_PROJECT_ID}" dns record-sets transaction abort -z "${GCP_DNS_ZONE_NAME}" 2>/dev/null || true; rm -f "${GCP_SERVICE_ACCOUNT_KEY_PATH}"' EXIT

  # Remove existing DNS records if present
  if [[ "${zone_info}" != "[]" ]]; then
    echo "Removing existing DNS records..."

    # Extract existing NS records
    outdated_dns_servers=($(echo "${zone_info}" | jq -r '.[0].rrdatas[]'))

    if [[ ${#outdated_dns_servers[@]} -gt 0 ]]; then
      gcloud --project="${GCP_DNS_PROJECT_ID}" \
        dns record-sets transaction remove \
        -z "${GCP_DNS_ZONE_NAME}" \
        --name "${GCP_DNS_RECORD_SET_NAME}" \
        --ttl "${GCP_DNS_RECORD_TTL}" \
        --type NS \
        "${outdated_dns_servers[@]}"
    fi
  fi

  # Add new DNS records if action is "add"
  if [[ "${ACTION}" == "add" ]]; then
    echo "Adding new DNS records..."
    gcloud --project="${GCP_DNS_PROJECT_ID}" \
      dns record-sets transaction add \
      -z "${GCP_DNS_ZONE_NAME}" \
      --name "${GCP_DNS_RECORD_SET_NAME}" \
      --ttl "${GCP_DNS_RECORD_TTL}" \
      --type NS \
      "${dns_servers[@]}"
  fi

  # Execute transaction
  echo "Executing DNS transaction..."
  gcloud --project="${GCP_DNS_PROJECT_ID}" \
    dns record-sets transaction execute \
    -z "${GCP_DNS_ZONE_NAME}"

  echo "DNS ${ACTION} operation completed successfully"

  # Verify DNS if requested
  if [[ "${CHECK_DNS}" == "true" && "${ACTION}" == "add" ]]; then
    echo "Waiting 90 seconds before DNS verification to avoid NXDOMAIN caching..."
    sleep 90

    DOMAIN="pcf.${GCP_DNS_RECORD_SET_NAME}"
    check_dns "${DOMAIN}"
  fi
}

main
