#!/usr/bin/env bash
#
# Nagios plugin for Spring Boot Actuator health.
# Fetches the actuator /health endpoint (JSON) and reports per-component status.
# Convention: the response has a top-level "status" plus a "components" map where
# every component (possibly nested via its own "components") also reports a
# "status". Anything whose status is not "UP" is treated as CRITICAL.
#
# Output:
#   OK       single summary line ("OK: status UP, N/N components UP")
#   CRITICAL one line per failing component
#
# Exit codes: 0=OK, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <url> [options]

Generic health check for Spring Boot Actuator. Treats any component whose
status is not 'UP' as CRITICAL.

Options:
  -u, --url URL            Actuator health URL (e.g. https://app/api/actuator/health)
  -T, --token TOKEN        Bearer token; sent as '<header>: Bearer <token>' (optional)
  -H, --header NAME        Header name carrying the token (default: Authorization)
  -e, --exclude REGEX      Ignore components whose path matches the anchored regex.
                           Comma-separated list and/or repeatable flag. Nested
                           components are addressed as 'parent/child'. Lenient:
                           a pattern matching nothing is not an error.
  -o, --ok SPEC            Extra status accepted as OK for matching components,
                           as '<component_or_regex>:<STATUS>' (e.g.
                           'contactForm:UNKNOWN'). UP is always OK. Status match
                           is case-sensitive. Comma-separated and/or repeatable.
  -k, --insecure           Allow insecure TLS (self-signed certs)
  -s, --short              Short output: on problems show only failing components.
                           Without -s, healthy components are also listed.
  -n, --nagios             Use <br/> instead of newlines (Nagios web UI)
  -t, --timeout SECONDS    Fetch timeout (default 10)
  -h, --help               Show this help

Examples:
  # Plain check
  $(basename "$0") -u https://portfolio.example.com/api/actuator/health

  # With a bearer token and short output for the Nagios web UI
  $(basename "$0") -u https://app/actuator/health -T "\$(bao kv get -field=token ...)" -s -n

  # Token carried by a custom header instead of Authorization
  $(basename "$0") -u https://app/actuator/health -H X-Auth-Token -T mytoken

  # Ignore a benign component that never reaches UP
  $(basename "$0") -u https://app/actuator/health -e 'contactForm'

  # Accept UNKNOWN as healthy for contactForm (still alerts on DOWN etc.)
  $(basename "$0") -u https://app/actuator/health -o 'contactForm:UNKNOWN'

Exit codes: 0=OK, 2=CRITICAL, 3=UNKNOWN
EOF
}

URL=""
TOKEN=""
HEADER_NAME="Authorization"
SHORT_MODE=0
NAGIOS_MODE=0
INSECURE=0
TIMEOUT=10
EXCLUDE_PATTERNS=()
OK_SPECS=()

split_csv_into() {
    # split_csv_into <array_name> <raw_value>: append comma-separated tokens
    # (whitespace-trimmed, empty skipped) to the named array.
    local -n arr="$1"
    local raw="$2" item
    local IFS=','
    local parts
    read -ra parts <<< "$raw"
    for item in "${parts[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && arr+=("$item")
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            URL="$2"; shift 2 ;;
        -T|--token)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TOKEN="$2"; shift 2 ;;
        -H|--header)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            HEADER_NAME="$2"; shift 2 ;;
        -e|--exclude)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into EXCLUDE_PATTERNS "$2"; shift 2 ;;
        -o|--ok)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into OK_SPECS "$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        -k|--insecure) INSECURE=1; shift ;;
        -s|--short) SHORT_MODE=1; shift ;;
        -n|--nagios) NAGIOS_MODE=1; shift ;;
        -h|--help) usage; exit "$EXIT_OK" ;;
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

if [[ -z "$URL" ]]; then
    print_msg "UNKNOWN: --url is required"
    usage >&2
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi

# Parse -o/--ok specs into parallel pattern/status arrays.
OK_PATTERNS=()
OK_STATUSES=()
for spec in "${OK_SPECS[@]}"; do
    if [[ ! "$spec" =~ ^(.+):([^:]+)$ ]]; then
        print_msg "UNKNOWN: Invalid -o/--ok spec '$spec' (expected COMPONENT_OR_REGEX:STATUS)"
        exit "$EXIT_UNKNOWN"
    fi
    OK_PATTERNS+=("${BASH_REMATCH[1]}")
    OK_STATUSES+=("${BASH_REMATCH[2]}")
done

need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $1"
        exit "$EXIT_UNKNOWN"
    fi
}
need_tool curl
need_tool jq

curl_args=(-fsS -m "$TIMEOUT")
[[ "$INSECURE" -eq 1 ]] && curl_args+=(-k)
[[ -n "$TOKEN" ]] && curl_args+=(-H "${HEADER_NAME}: Bearer ${TOKEN}")

# Actuator returns HTTP 503 when status is DOWN; -f makes curl fail on that, but
# the body still carries the JSON we want. Capture body and exit code separately.
body=$(curl "${curl_args[@]}" "$URL" 2>/dev/null)
curl_rc=$?
if [[ -z "$body" ]]; then
    print_msg "CRITICAL: No response from $URL (curl exit $curl_rc)"
    exit "$EXIT_CRITICAL"
fi

if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
    print_msg "CRITICAL: Response from $URL is not valid JSON"
    exit "$EXIT_CRITICAL"
fi

overall=$(jq -r '.status // empty' <<<"$body")
if [[ -z "$overall" ]]; then
    print_msg "UNKNOWN: Response has no top-level 'status' field (not a Spring Actuator health endpoint?)"
    exit "$EXIT_UNKNOWN"
fi

# Flatten components into "<path>\t<status>\t<reason>" lines, recursing into any
# component that itself nests a "components" map. Nested paths use '/'.
leaves=$(jq -r '
    def leaves($prefix):
        to_entries[]
        | (if $prefix == "" then .key else $prefix + "/" + .key end) as $path
        | .value as $v
        | if ($v | type) == "object" and ($v | has("components"))
          then ($v.components | leaves($path))
          else [ $path,
                 ($v.status // "UNKNOWN" | tostring),
                 ($v.details.reason // $v.details.error // "" | tostring) ] | @tsv
          end;
    (.components // {}) | leaves("")
' <<<"$body")

excluded() {
    local name="$1" pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        [[ "$name" =~ ^${pattern}$ ]] && return 0
    done
    return 1
}

# A component status is OK if it's UP, or if an -o/--ok spec whitelists this
# exact status for a component matching the spec's anchored regex.
status_ok() {
    local name="$1" st="$2" i
    [[ "$st" == "UP" ]] && return 0
    for ((i=0; i<${#OK_PATTERNS[@]}; i++)); do
        if [[ "$name" =~ ^${OK_PATTERNS[$i]}$ && "$st" == "${OK_STATUSES[$i]}" ]]; then
            return 0
        fi
    done
    return 1
}

CRIT_LINES=()
OK_LINES=()
total=0

while IFS=$'\t' read -r comp status reason; do
    [[ -z "$comp" ]] && continue
    excluded "$comp" && continue
    total=$(( total + 1 ))
    if status_ok "$comp" "$status"; then
        OK_LINES+=("OK: Component '$comp' is $status")
    else
        if [[ -n "$reason" ]]; then
            CRIT_LINES+=("CRITICAL: Component '$comp' is $status ($reason)")
        else
            CRIT_LINES+=("CRITICAL: Component '$comp' is $status")
        fi
    fi
done <<< "$leaves"

# Safety net: overall status not UP but there are no components to explain it
# (status comes from a non-component contributor). Don't let it pass silently.
# When components exist, the per-component verdict is authoritative — an
# overall mismatch there is due to a component we already accepted via -o.
if [[ "$overall" != "UP" && $total -eq 0 ]]; then
    CRIT_LINES+=("CRITICAL: overall status is $overall")
fi

ok_count=$(( total - ${#CRIT_LINES[@]} ))
(( ok_count < 0 )) && ok_count=0

if [[ ${#CRIT_LINES[@]} -eq 0 ]]; then
    print_msg "OK: Overall status is $overall, ${ok_count}/${total} components OK"
    exit "$EXIT_OK"
fi

output_lines=("${CRIT_LINES[@]}")
if [[ "$SHORT_MODE" -ne 1 && ${#OK_LINES[@]} -gt 0 ]]; then
    output_lines+=("${OK_LINES[@]}")
fi

out=$(printf '%s\n' "${output_lines[@]}")
print_msg "$out"
exit "$EXIT_CRITICAL"
