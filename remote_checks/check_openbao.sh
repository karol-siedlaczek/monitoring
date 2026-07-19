#!/usr/bin/env bash
#
# Nagios plugin for OpenBao health.
# Authenticates via AppRole, queries /sys/health, /sys/leader and /sys/key-status,
# and reports overall status. The AppRole-derived token is revoked at exit.
#
# Severity:
#   CRITICAL  not initialized, sealed, AppRole login 4xx, key-status 4xx,
#             standby/performance_standby with --expect-active
#   OK        active+unsealed, or standby/perf-standby without --expect-active
#   UNKNOWN   network error, 5xx, parse error, missing token in login response
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <url> [-R <role_id>] [-S <secret_id>] [options]

Options:
  -u, --url URL              OpenBao base URL (e.g. https://bao.example.com)
                             (falls back to env \$BAO_ADDR)
  -R, --role-id ID           AppRole role_id (falls back to env \$BAO_ROLE_ID)
  -S, --secret-id ID         AppRole secret_id (falls back to env \$BAO_SECRET_ID)
  -A, --auth-path PATH       AppRole mount path (default: approle)
  -e, --expect-active        Treat standby/performance_standby as CRITICAL
  -n, --nagios               Replace newlines with <br/> for Nagios web UI
  -t, --timeout SECONDS      HTTP timeout in seconds (default: 10)
  -h, --help                 Show this help

Environment variables:
  BAO_ADDR                   Used when -u/--url is not provided
  BAO_ROLE_ID                Used when -R/--role-id is not provided
  BAO_SECRET_ID              Used when -S/--secret-id is not provided

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

URL=""
ROLE_ID=""
SECRET_ID=""
AUTH_PATH="approle"
EXPECT_ACTIVE=0
NAGIOS_MODE=0
TIMEOUT=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            URL="$2"; shift 2 ;;
        -R|--role-id)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            ROLE_ID="$2"; shift 2 ;;
        -S|--secret-id)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            SECRET_ID="$2"; shift 2 ;;
        -A|--auth-path)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            AUTH_PATH="$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        -e|--expect-active)
            EXPECT_ACTIVE=1; shift ;;
        -n|--nagios)
            NAGIOS_MODE=1; shift ;;
        -h|--help)
            usage; exit "$EXIT_UNKNOWN" ;;
        *)
            echo "UNKNOWN: Unknown argument: $1" >&2
            usage >&2
            exit "$EXIT_UNKNOWN" ;;
    esac
done

print_msg() {
    local msg="$1"
    if [[ "$NAGIOS_MODE" -eq 1 ]]; then
        printf '%s\n' "${msg//$'\n'/<br/>}"
    else
        printf '%s\n' "$msg"
    fi
}

URL="${URL:-${BAO_ADDR:-}}"
ROLE_ID="${ROLE_ID:-${BAO_ROLE_ID:-}}"
SECRET_ID="${SECRET_ID:-${BAO_SECRET_ID:-}}"

if [[ -z "$URL" ]]; then
    print_msg "UNKNOWN: url not provided (use -u/--url or set BAO_ADDR env var)"
    exit "$EXIT_UNKNOWN"
fi

if [[ -z "$ROLE_ID" ]]; then
    print_msg "UNKNOWN: role_id not provided (use -R/--role-id or set BAO_ROLE_ID env var)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$SECRET_ID" ]]; then
    print_msg "UNKNOWN: secret_id not provided (use -S/--secret-id or set BAO_SECRET_ID env var)"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $tool"
        exit "$EXIT_UNKNOWN"
    fi
done

URL="${URL%/}"

body_file=$(mktemp)
CLIENT_TOKEN=""

cleanup() {
    if [[ -n "$CLIENT_TOKEN" ]]; then
        curl -sS -m "$TIMEOUT" -X POST \
            -H "X-Vault-Token: $CLIENT_TOKEN" \
            "$URL/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
    fi
    rm -f "$body_file"
}
trap cleanup EXIT

api_get() {
    # api_get <path> [extra_curl_args...]
    # Writes body to $body_file, prints HTTP code on stdout, returns curl exit status.
    local path="$1"; shift
    curl -sS -m "$TIMEOUT" \
        -o "$body_file" \
        -w '%{http_code}' \
        "$@" \
        "$URL$path" 2>/dev/null
}

# 1. /sys/health (unauthenticated). OpenBao encodes health in the HTTP status:
#    200 active, 429 standby, 473 perf-standby (429/473 normalized to 200 by the
#    standbyok/perfstandbyok params below), 501 not initialized, 503 sealed.
#    The body is valid health JSON in all of those cases — including 501/503 —
#    so we parse the JSON fields first and only fall back to a generic UNKNOWN
#    when the body isn't the health payload we expect (real 5xx from a proxy,
#    or a dropped connection / HTTP 000 with no body).
http_code=$(api_get "/v1/sys/health?standbyok=true&perfstandbyok=true") || {
    print_msg "CRITICAL: Failed to reach /sys/health at $URL"
    exit "$EXIT_CRITICAL"
}

body=$(cat "$body_file")

if ! echo "$body" | jq -e 'has("initialized") and has("sealed")' >/dev/null 2>&1; then
    print_msg "CRITICAL: /sys/health returned HTTP $http_code with unexpected body"
    exit "$EXIT_CRITICAL"
fi

initialized=$(echo "$body" | jq -r '.initialized')
sealed=$(echo "$body" | jq -r '.sealed')
standby=$(echo "$body" | jq -r '.standby')
perf_standby=$(echo "$body" | jq -r '.performance_standby // false')
version=$(echo "$body" | jq -r '.version // "unknown"')
cluster_name=$(echo "$body" | jq -r '.cluster_name // "unknown"')

# Short-circuit on hard failures so we report the actual problem rather than
# "AppRole login failed" (which would be the symptom, not the cause). These are
# driven by the JSON fields, so a 503-sealed reports "sealed" and a 501 reports
# "not initialized" instead of a meaningless "HTTP 5xx".
if [[ "$initialized" != "true" ]]; then
    print_msg "CRITICAL: OpenBao is not initialized (v$version)"
    exit "$EXIT_CRITICAL"
fi
if [[ "$sealed" == "true" ]]; then
    # A sealed OpenBao omits cluster_name from /sys/health, so don't print it
    # here — it would always be a meaningless "cluster=unknown".
    print_msg "CRITICAL: OpenBao is sealed (v$version)"
    exit "$EXIT_CRITICAL"
fi

# 2. AppRole login
login_payload=$(jq -nc --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id:$r, secret_id:$s}')
http_code=$(api_get "/v1/auth/$AUTH_PATH/login" \
    -X POST \
    -H "Content-Type: application/json" \
    --data "$login_payload") || {
    print_msg "UNKNOWN: Failed to reach AppRole login at $URL/v1/auth/$AUTH_PATH/login"
    exit "$EXIT_UNKNOWN"
}

body=$(cat "$body_file")

if [[ "$http_code" =~ ^5 ]] || [[ "$http_code" == "000" ]]; then
    print_msg "UNKNOWN: AppRole login returned HTTP $http_code"
    exit "$EXIT_UNKNOWN"
fi

if [[ "$http_code" != "200" ]]; then
    err_msg=$(echo "$body" | jq -r '.errors // [] | join(", ")' 2>/dev/null)
    print_msg "CRITICAL: AppRole login failed (HTTP $http_code)${err_msg:+: $err_msg}"
    exit "$EXIT_CRITICAL"
fi

CLIENT_TOKEN=$(echo "$body" | jq -r '.auth.client_token // empty' 2>/dev/null)
if [[ -z "$CLIENT_TOKEN" ]]; then
    print_msg "UNKNOWN: AppRole login returned no client_token"
    exit "$EXIT_UNKNOWN"
fi

# 3. /sys/key-status — confirms the AppRole token actually works
http_code=$(api_get "/v1/sys/key-status" -H "X-Vault-Token: $CLIENT_TOKEN") || {
    print_msg "UNKNOWN: Failed to reach /sys/key-status at $URL"
    exit "$EXIT_UNKNOWN"
}

if [[ "$http_code" =~ ^4 ]]; then
    body=$(cat "$body_file")
    err_msg=$(echo "$body" | jq -r '.errors // [] | join(", ")' 2>/dev/null)
    print_msg "CRITICAL: /sys/key-status returned HTTP $http_code (token policy issue?)${err_msg:+: $err_msg}"
    exit "$EXIT_CRITICAL"
fi
if [[ "$http_code" != "200" ]]; then
    print_msg "UNKNOWN: /sys/key-status returned HTTP $http_code"
    exit "$EXIT_UNKNOWN"
fi

# 4. /sys/leader — best-effort; only used to enrich output, never fails the check
leader_addr=""
is_self="false"
if http_code=$(api_get "/v1/sys/leader") && [[ "$http_code" == "200" ]]; then
    body=$(cat "$body_file")
    if echo "$body" | jq -e . >/dev/null 2>&1; then
        leader_addr=$(echo "$body" | jq -r '.leader_address // ""')
        is_self=$(echo "$body" | jq -r '.is_self // false')
    fi
fi

# 5. Standby evaluation
ha_state=""
if [[ "$standby" == "true" ]]; then
    ha_state="standby"
elif [[ "$perf_standby" == "true" ]]; then
    ha_state="performance standby"
fi

if [[ -n "$ha_state" && "$EXPECT_ACTIVE" -eq 1 ]]; then
    suffix=""
    [[ -n "$leader_addr" ]] && suffix=" (leader=$leader_addr)"
    print_msg "CRITICAL: OpenBao is in $ha_state mode${suffix}"
    exit "$EXIT_CRITICAL"
fi

ha_suffix=""
if [[ -n "$ha_state" ]]; then
    ha_suffix=", $ha_state"
elif [[ "$is_self" == "true" ]]; then
    ha_suffix=", active leader"
fi

print_msg "OK: OpenBao v$version unsealed (cluster=$cluster_name${ha_suffix})"
exit "$EXIT_OK"
