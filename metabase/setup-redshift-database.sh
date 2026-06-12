#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
ENV_FILE="${SCRIPT_DIR}/.env"

load_env_file() {
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" != *"="* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      if [[ "${value}" =~ ^\".*\"$ || "${value}" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
      fi
      export "${key}=${value}"
    fi
  done < "$1"
}

if [[ -f "${ENV_FILE}" ]]; then
  load_env_file "${ENV_FILE}"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq

METABASE_URL="${METABASE_URL:-http://localhost:${METABASE_HOST_PORT:-3001}}"
METABASE_ADMIN_EMAIL="${METABASE_ADMIN_EMAIL:-admin@example.com}"
METABASE_ADMIN_PASSWORD="${METABASE_ADMIN_PASSWORD:-ChangeThisMetabasePassword123!}"
METABASE_ADMIN_FIRST_NAME="${METABASE_ADMIN_FIRST_NAME:-DataOps}"
METABASE_ADMIN_LAST_NAME="${METABASE_ADMIN_LAST_NAME:-Admin}"
METABASE_DATABASE_NAME="${METABASE_DATABASE_NAME:-Nash DataOps Redshift Dev}"

AWS_PROFILE="${AWS_PROFILE:-cloud-user}"
AWS_REGION="${AWS_REGION:-us-west-1}"
REDSHIFT_CLUSTER_IDENTIFIER="${REDSHIFT_CLUSTER_IDENTIFIER:-dataops-demo-cluster-dev}"
REDSHIFT_PORT="${REDSHIFT_PORT:-5439}"
REDSHIFT_DATABASE="${REDSHIFT_DATABASE:-dev}"
REDSHIFT_SCHEMA="${REDSHIFT_SCHEMA:-nyc_taxi}"
REDSHIFT_USERNAME="${REDSHIFT_USERNAME:-admin}"

terraform_output() {
  local output_name="$1"
  if command -v terraform >/dev/null 2>&1 && [[ -d "${TERRAFORM_DIR}" ]]; then
    terraform -chdir="${TERRAFORM_DIR}" output -raw "${output_name}" 2>/dev/null || true
  fi
}

discover_redshift_host() {
  local host
  host="$(terraform_output redshift_host)"
  if [[ -n "${host}" ]]; then
    echo "${host}"
    return
  fi

  if command -v aws >/dev/null 2>&1; then
    AWS_PROFILE="${AWS_PROFILE}" AWS_REGION="${AWS_REGION}" \
      aws redshift describe-clusters \
        --cluster-identifier "${REDSHIFT_CLUSTER_IDENTIFIER}" \
        --query 'Clusters[0].Endpoint.Address' \
        --output text
  fi
}

REDSHIFT_HOST="${REDSHIFT_HOST:-$(discover_redshift_host)}"

if [[ -z "${REDSHIFT_HOST}" || "${REDSHIFT_HOST}" == "None" ]]; then
  echo "REDSHIFT_HOST is not set and could not be discovered." >&2
  echo "Set REDSHIFT_HOST in ${ENV_FILE} or run Terraform from ../terraform." >&2
  exit 1
fi

if [[ -z "${REDSHIFT_PASSWORD:-}" || "${REDSHIFT_PASSWORD}" == "ReplaceWithYourTerraformRedshiftPassword" ]]; then
  echo "Set REDSHIFT_PASSWORD in ${ENV_FILE} before registering Redshift." >&2
  exit 1
fi

echo "Waiting for Metabase at ${METABASE_URL}..."
for _ in {1..90}; do
  if curl -fsS "${METABASE_URL}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! curl -fsS "${METABASE_URL}/api/health" >/dev/null 2>&1; then
  echo "Metabase did not become healthy. Check: docker compose logs metabase-app" >&2
  exit 1
fi

session_properties="$(curl -fsS "${METABASE_URL}/api/session/properties")"
setup_token="$(jq -r '."setup-token" // empty' <<<"${session_properties}")"
has_user_setup="$(jq -r '."has-user-setup" // false' <<<"${session_properties}")"

if [[ -n "${setup_token}" && "${has_user_setup}" != "true" ]]; then
  echo "Creating local Metabase admin user..."
  setup_payload="$(
    jq -n \
      --arg token "${setup_token}" \
      --arg first_name "${METABASE_ADMIN_FIRST_NAME}" \
      --arg last_name "${METABASE_ADMIN_LAST_NAME}" \
      --arg email "${METABASE_ADMIN_EMAIL}" \
      --arg password "${METABASE_ADMIN_PASSWORD}" \
      '{
        token: $token,
        user: {
          first_name: $first_name,
          last_name: $last_name,
          email: $email,
          password: $password
        },
        prefs: {
          site_name: "Nash DataOps Demo",
          site_locale: "en",
          allow_tracking: false
        }
      }'
  )"
  curl -fsS \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${setup_payload}" \
    "${METABASE_URL}/api/setup" >/dev/null
fi

session_id="$(
  jq -n \
    --arg username "${METABASE_ADMIN_EMAIL}" \
    --arg password "${METABASE_ADMIN_PASSWORD}" \
    '{username: $username, password: $password}' |
  curl -fsS \
    -H "Content-Type: application/json" \
    -X POST \
    -d @- \
    "${METABASE_URL}/api/session" |
  jq -r '.id'
)"

if [[ -z "${session_id}" || "${session_id}" == "null" ]]; then
  echo "Could not sign in to Metabase. Check METABASE_ADMIN_EMAIL and METABASE_ADMIN_PASSWORD." >&2
  exit 1
fi

database_payload="$(
  jq -n \
    --arg name "${METABASE_DATABASE_NAME}" \
    --arg host "${REDSHIFT_HOST}" \
    --arg dbname "${REDSHIFT_DATABASE}" \
    --arg user "${REDSHIFT_USERNAME}" \
    --arg password "${REDSHIFT_PASSWORD}" \
    --arg schema "${REDSHIFT_SCHEMA}" \
    --argjson port "${REDSHIFT_PORT}" \
    '{
      name: $name,
      engine: "redshift",
      details: {
        host: $host,
        port: $port,
        dbname: $dbname,
        user: $user,
        password: $password,
        ssl: true,
        "schema-filters-type": "inclusion",
        "schema-filters-patterns": $schema
      },
      is_full_sync: true,
      is_on_demand: false,
      schedules: {}
    }'
)"

existing_database_id="$(
  curl -fsS \
    -H "X-Metabase-Session: ${session_id}" \
    "${METABASE_URL}/api/database" |
  jq -r --arg name "${METABASE_DATABASE_NAME}" '.data[]? | select(.name == $name) | .id' |
  head -n 1
)"

if [[ -n "${existing_database_id}" ]]; then
  echo "Updating existing Metabase database ${existing_database_id}..."
  database_id="${existing_database_id}"
  curl -fsS \
    -H "Content-Type: application/json" \
    -H "X-Metabase-Session: ${session_id}" \
    -X PUT \
    -d "${database_payload}" \
    "${METABASE_URL}/api/database/${database_id}" >/dev/null
else
  echo "Creating Metabase Redshift database connection..."
  database_id="$(
    curl -fsS \
      -H "Content-Type: application/json" \
      -H "X-Metabase-Session: ${session_id}" \
      -X POST \
      -d "${database_payload}" \
      "${METABASE_URL}/api/database" |
    jq -r '.id'
  )"
fi

echo "Triggering Metabase schema sync for database ${database_id}..."
curl -fsS \
  -H "X-Metabase-Session: ${session_id}" \
  -X POST \
  "${METABASE_URL}/api/database/${database_id}/sync_schema" >/dev/null || true

cat <<EOF
Metabase is configured.

URL: ${METABASE_URL}
Database: ${METABASE_DATABASE_NAME}
Redshift: ${REDSHIFT_HOST}:${REDSHIFT_PORT}/${REDSHIFT_DATABASE}
Schema: ${REDSHIFT_SCHEMA}
EOF
