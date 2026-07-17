#!/usr/bin/env bash
# Check Portainer environments (agents), stacks and containers health.
# Exit codes (Nagios-style): 0=OK, 2=CRITICAL, 3=UNKNOWN.

set -euo pipefail

EXIT_OK=0
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
  cat <<EOF
Usage: $(basename "$0") --url URL --token TOKEN [--nagios]

Options:
  -u, --url URL      Portainer base URL (e.g. https://portainer.example.com)
  -t, --token TOKEN  Portainer API key (read-only monitoring user)
  -n, --nagios       Join multiple CRITICAL lines with <br/> instead of newlines
  -h, --help         Show this help

Example:
  $(basename "$0") \\
    --url https://portainer.example.com \\
    --token "\$(bao kv get -mount=portainer -field=token api-keys/monitoring)"
EOF
}

url=""
token=""
nagios_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)    url="$2"; shift 2 ;;
    -t|--token)  token="$2"; shift 2 ;;
    -n|--nagios) nagios_mode=true; shift ;;
    -h|--help)   usage; exit "$EXIT_OK" ;;
    *)           echo "Unknown argument: $1" >&2; usage >&2; exit "$EXIT_UNKNOWN" ;;
  esac
done

if [[ -z "$url" || -z "$token" ]]; then
  echo "UNKNOWN: --url and --token are required" >&2
  usage >&2
  exit "$EXIT_UNKNOWN"
fi

api() {
  curl -fs --max-time 10 \
    -H "X-API-Key: ${token}" \
    "${url%/}$1" 2>/dev/null
}

problems=()

endpoints_json=$(api /api/endpoints) || {
  echo "UNKNOWN: Cannot reach Portainer API at ${url}"
  exit "$EXIT_UNKNOWN"
}

while IFS=$'\t' read -r name status endpoint_url; do
  if [[ "$status" != "1" ]]; then
    problems+=("CRITICAL: Environment ${name} (${endpoint_url}) is down")
  fi
done < <(jq -r '.[] | "\(.Name)\t\(.Status)\t\(.URL)"' <<<"$endpoints_json")

stacks_json=$(api /api/stacks) || {
  echo "UNKNOWN: Cannot list stacks"
  exit "$EXIT_UNKNOWN"
}

env_count=$(jq 'length' <<<"$endpoints_json")
stack_count=$(jq 'length' <<<"$stacks_json")

if [[ "$stack_count" -eq 0 ]]; then
  problems+=("CRITICAL: Portainer API returned 0 stacks (check API token permissions)")
else
  while IFS=$'\t' read -r name status; do
    # Stack status: 1 = active, 2 = inactive
    if [[ "$status" != "1" ]]; then
      problems+=("CRITICAL: Docker stack ${name} is inactive")
    fi
  done < <(jq -r '.[] | "\(.Name)\t\(.Status)"' <<<"$stacks_json")
fi

container_count=0

while IFS=$'\t' read -r env_id env_name env_status env_url; do
  if [[ "$env_status" != "1" ]]; then
    continue
  fi

  containers_json=$(api "/api/endpoints/${env_id}/docker/containers/json?all=1") || {
    # Portainer reports endpoint Status=1 but agent proxy fails (502 etc.) — agent is unreachable
    problems+=("CRITICAL: Environment ${env_name} (${env_url}) is down")
    continue
  }

  env_container_count=$(jq 'length' <<<"$containers_json")
  container_count=$((container_count + env_container_count))

  while IFS=$'\t' read -r cname cstate cstatus; do
    if [[ "$cstate" != "running" ]]; then
      problems+=("CRITICAL: Container ${cname} on ${env_name} is ${cstate}")
    elif [[ "$cstatus" == *"(unhealthy)"* ]]; then
      problems+=("CRITICAL: Container ${cname} on ${env_name} is unhealthy")
    fi
  done < <(jq -r '.[] | "\(.Names[0] | sub("^/"; ""))\t\(.State)\t\(.Status)"' <<<"$containers_json")
done < <(jq -r '.[] | "\(.Id)\t\(.Name)\t\(.Status)\t\(.URL)"' <<<"$endpoints_json")

if [[ ${#problems[@]} -eq 0 ]]; then
  echo "OK: ${env_count} environments up, ${stack_count} stacks healthy, ${container_count} containers running"
  exit "$EXIT_OK"
fi

if [[ "$nagios_mode" == true ]]; then
  out="${problems[0]}"
  for ((i=1; i<${#problems[@]}; i++)); do
    out+="<br/>${problems[$i]}"
  done
  echo "$out"
else
  printf '%s\n' "${problems[@]}"
fi
exit "$EXIT_CRITICAL"
