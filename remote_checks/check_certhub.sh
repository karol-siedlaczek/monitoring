#!/usr/bin/env bash
#
# Nagios plugin for Cert Hub.
# Queries /api/certs/status and reports overall status with per-certificate details.
#
# Per-certificate severity mapping:
#   CRITICAL  status=EXPIRED, or status=EXPIRING and days_to_expire <= --critical
#   WARNING   status=EXPIRING and days_to_expire <= --warning, any other non-OK status
#   OK        status=EXPIRING and days_to_expire >  --warning (suppressed from output)
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <url> -T <token> -w <days> -c <days> [-n|--nagios] [-t <seconds>]

Options:
  -u, --url URL          Cert Hub API base URL (e.g. https://certhub.example.com)
  -T, --token TOKEN      Bearer token in form <id>.<token>
  -w, --warning DAYS     Warn when an EXPIRING certificate has <= DAYS to expire
  -c, --critical DAYS    Critical when an EXPIRING certificate has <= DAYS to expire
  -n, --nagios           Replace newlines with <br> for rendering in Nagios web UI
  -t, --timeout SECONDS  HTTP timeout in seconds (default: 10)
  -h, --help             Show this help

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

URL=""
TOKEN=""
WARNING_DAYS=""
CRITICAL_DAYS=""
NAGIOS_MODE=0
TIMEOUT=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            URL="$2"; shift 2 ;;
        -T|--token)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TOKEN="$2"; shift 2 ;;
        -w|--warning)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            WARNING_DAYS="$2"; shift 2 ;;
        -c|--critical)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            CRITICAL_DAYS="$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
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
        printf '%s\n' "${msg//$'\n'/<br>}"
    else
        printf '%s\n' "$msg"
    fi
}

if [[ -z "$URL" ]]; then
    print_msg "UNKNOWN: Missing required -u/--url argument"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$TOKEN" ]]; then
    print_msg "UNKNOWN: Missing required -T/--token argument"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$WARNING_DAYS" ]]; then
    print_msg "UNKNOWN: Missing required -w/--warning argument"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$CRITICAL_DAYS" ]]; then
    print_msg "UNKNOWN: Missing required -c/--critical argument"
    exit "$EXIT_UNKNOWN"
fi

if ! [[ "$WARNING_DAYS" =~ ^[0-9]+$ ]]; then
    print_msg "UNKNOWN: -w/--warning must be a non-negative integer, got: '$WARNING_DAYS'"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$CRITICAL_DAYS" =~ ^[0-9]+$ ]]; then
    print_msg "UNKNOWN: -c/--critical must be a non-negative integer, got: '$CRITICAL_DAYS'"
    exit "$EXIT_UNKNOWN"
fi
if (( WARNING_DAYS < CRITICAL_DAYS )); then
    print_msg "UNKNOWN: -w/--warning ($WARNING_DAYS) must be greater than or equal to -c/--critical ($CRITICAL_DAYS)"
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
trap 'rm -f "$body_file"' EXIT

http_code=$(curl -sS -m "$TIMEOUT" \
    -o "$body_file" \
    -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$URL/api/certs/status?exclude_ok=true" 2>/dev/null) || {
    print_msg "UNKNOWN: Failed to reach API at $URL"
    exit "$EXIT_UNKNOWN"
}

body=$(cat "$body_file")

if [[ "$http_code" != "200" ]]; then
    err_msg=$(echo "$body" | jq -r '[.message, .detail] | map(select(. != null and . != "")) | join(" - ")' 2>/dev/null)
    print_msg "UNKNOWN: API returned HTTP $http_code${err_msg:+: $err_msg}"
    exit "$EXIT_UNKNOWN"
fi

if ! echo "$body" | jq -e . >/dev/null 2>&1; then
    print_msg "UNKNOWN: Failed to parse API response as JSON"
    exit "$EXIT_UNKNOWN"
fi

lines=$(echo "$body" | jq -r --argjson warn "$WARNING_DAYS" --argjson crit "$CRITICAL_DAYS" '
    .data.certs[]
    | . as $cert
    | (
        if   $cert.status == "EXPIRED"  then "CRITICAL"
        elif $cert.status == "EXPIRING" then
          if   ($cert.days_to_expire // 0) <= $crit then "CRITICAL"
          elif ($cert.days_to_expire // 0) <= $warn then "WARNING"
          else null
          end
        else "WARNING"
        end
      ) as $severity
    | select($severity != null)
    | (
        if $cert.expire_date != null
        then " (\($cert.expire_date), \($cert.days_to_expire // "unknown") days left)"
        else ""
        end
      ) as $tail
    | "\($severity): Certificate \($cert.id) status is \($cert.status)\($tail)"
')

if [[ -z "$lines" ]]; then
    print_msg "OK: All certificates are issued and up to date"
    exit "$EXIT_OK"
fi

if grep -q '^CRITICAL:' <<<"$lines"; then
    exit_code="$EXIT_CRITICAL"
else
    exit_code="$EXIT_WARNING"
fi

print_msg "$lines"
exit "$exit_code"
