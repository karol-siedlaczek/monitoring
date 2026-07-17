#!/usr/bin/env bash
#
# Nagios plugin for Django app health (ergo-bhp / service-desk).
# The apps expose two endpoints:
#   /healthz  full health check, protected by a Bearer token. Returns JSON with
#             a top-level "status" (ok|degraded|fail) and a "components" map
#             (database, redis, smtp), each with its own status + detail.
#   /health   liveness only, no auth. Returns HTTP 200 with body exactly 'ok'.
#
# Mode is selected by the token:
#   token given  (-t ...)  -> /healthz JSON mode (sends 'Authorization: Bearer')
#   token empty            -> /health liveness mode (no auth header, expects 'ok')
# Point -u at the matching URL.
#
# Severity mapping (/healthz):
#   HTTP 200 + status ok        -> OK
#   HTTP 200 + status degraded  -> WARNING (database+redis OK, SMTP down);
#                                  --degraded-ok downgrades this to OK
#   HTTP 503 + status fail      -> CRITICAL (a critical component is down)
#   HTTP 401 / 403 / 404        -> UNKNOWN (auth failure, or /healthz disabled
#                                  because the token isn't configured app-side:
#                                  403 on ergo-bhp, 404 on service-desk)
#   no response / TLS error     -> CRITICAL (app unreachable)
# Components reporting "disabled" are intentionally off and never an error.
#
# Severity mapping (/health):
#   HTTP 200 + body 'ok'        -> OK
#   HTTP 200 + other body       -> WARNING (responding, unexpected body)
#   non-200 / no response       -> CRITICAL
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <url> [options]

Health check for the Django apps (ergo-bhp, service-desk). With a token it
parses the protected /healthz JSON; without a token it runs the unauthenticated
/health liveness probe.

Options:
  -u, --url URL            Endpoint URL (e.g. https://app.example.com/healthz)
  -t, --token TOKEN        Bearer token for /healthz. Empty -> liveness mode
                           (no auth header, point -u at /health). The token
                           VALUE differs per app (ergo-bhp: PROMETHEUS_METRICS_TOKEN,
                           service-desk: MONITORING_TOKEN); the plugin sends it
                           the same way for both.
  -k, --insecure           Skip TLS certificate verification
  -w, --degraded-warning   Treat 'degraded' as WARNING (default)
      --degraded-ok        Treat 'degraded' as OK (ignore SMTP being down)
  -T, --timeout SECONDS    curl timeout (default: 10)
  -s, --short              Short output: single summary line when OK; only
                           failing components on problems (default lists all).
  -n, --nagios             Use <br/> instead of newlines (Nagios web UI)
  -h, --help               Show this help

Examples:
  # Full health check, ergo-bhp
  $(basename "$0") -u https://ergo-bhp.example.com/healthz -t "\$(bao kv get -field=token ...)"

  # Full health check, service-desk, short + web output
  $(basename "$0") -u https://service-desk.example.com/healthz -t "\$MONITORING_TOKEN" -s -n

  # Liveness only (no token)
  $(basename "$0") -u https://ergo-bhp.example.com/health

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

URL=""
TOKEN=""
INSECURE=0
DEGRADED_LEVEL="warning"   # warning | ok
TIMEOUT=10
SHORT_MODE=0
NAGIOS_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            URL="$2"; shift 2 ;;
        -t|--token)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TOKEN="$2"; shift 2 ;;
        -k|--insecure)         INSECURE=1; shift ;;
        -w|--degraded-warning) DEGRADED_LEVEL="warning"; shift ;;
        --degraded-ok)         DEGRADED_LEVEL="ok"; shift ;;
        -T|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        -s|--short)            SHORT_MODE=1; shift ;;
        -n|--nagios)           NAGIOS_MODE=1; shift ;;
        -h|--help)             usage; exit "$EXIT_OK" ;;
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

need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $1"
        exit "$EXIT_UNKNOWN"
    fi
}
need_tool curl
need_tool jq

# Liveness mode (/health): no token -> no auth header, expect body 'ok'.
LIVENESS=0
[[ -z "$TOKEN" ]] && LIVENESS=1

# Fetch: capture body and HTTP status in one request. The status code is
# appended after a final newline so 503/401 bodies are still available (no -f).
curl_args=(-sS -m "$TIMEOUT" -w $'\n%{http_code}')
[[ "$INSECURE" -eq 1 ]] && curl_args+=(-k)
[[ -n "$TOKEN" ]] && curl_args+=(-H "Authorization: Bearer ${TOKEN}")

response=$(curl "${curl_args[@]}" "$URL" 2>/dev/null)
curl_rc=$?
http_code="${response##*$'\n'}"
body="${response%$'\n'*}"
[[ "$response" == "$http_code" ]] && body=""   # no body, only the code

if [[ $curl_rc -ne 0 || -z "$http_code" || "$http_code" == "000" ]]; then
    print_msg "CRITICAL: No response from $URL (curl exit $curl_rc)"
    exit "$EXIT_CRITICAL"
fi

# --- Liveness mode (/health) ---------------------------------------------------
if [[ "$LIVENESS" -eq 1 ]]; then
    live_body="$(printf '%s' "$body" | tr -d '[:space:]')"
    if [[ "$http_code" == "200" && "$live_body" == "ok" ]]; then
        print_msg "OK: Django liveness - process alive (HTTP 200, body 'ok')"
        exit "$EXIT_OK"
    fi
    if [[ "$http_code" == "200" ]]; then
        print_msg "WARNING: Django liveness - HTTP 200 but unexpected body '$live_body' (expected 'ok')"
        exit "$EXIT_WARNING"
    fi
    print_msg "CRITICAL: Django liveness - HTTP $http_code from $URL"
    exit "$EXIT_CRITICAL"
fi

# --- Full health mode (/healthz) ----------------------------------------------
case "$http_code" in
    401)
        print_msg "UNKNOWN: HTTP 401 from $URL - authorization failed (invalid or missing token)"
        exit "$EXIT_UNKNOWN" ;;
    403)
        print_msg "UNKNOWN: HTTP 403 from $URL - authorization failed, or /healthz disabled (token not configured app-side)"
        exit "$EXIT_UNKNOWN" ;;
    404)
        print_msg "UNKNOWN: HTTP 404 from $URL - endpoint not found (/healthz disabled / token not configured, or wrong path)"
        exit "$EXIT_UNKNOWN" ;;
    200|503) ;;   # carry on, body holds the health JSON
    *)
        print_msg "UNKNOWN: Unexpected HTTP $http_code from $URL"
        exit "$EXIT_UNKNOWN" ;;
esac

if [[ -z "$body" ]] || ! jq -e . >/dev/null 2>&1 <<<"$body"; then
    print_msg "UNKNOWN: Response from $URL is not valid JSON (HTTP $http_code)"
    exit "$EXIT_UNKNOWN"
fi

overall=$(jq -r '.status // empty' <<<"$body")
if [[ -z "$overall" ]]; then
    print_msg "UNKNOWN: Response from $URL has no top-level 'status' field"
    exit "$EXIT_UNKNOWN"
fi

# Flatten components into "<name>\t<status>\t<detail>" lines.
components=$(jq -r '
    (.components // {})
    | to_entries[]
    | [ .key,
        (.value.status // "unknown" | tostring),
        (.value.detail // "" | tostring) ] | @tsv
' <<<"$body")

OK_LINES=()
PROBLEM_LINES=()
ntotal=0
nok=0
while IFS=$'\t' read -r name status detail; do
    [[ -z "$name" ]] && continue
    ntotal=$(( ntotal + 1 ))
    case "$status" in
        ok|disabled)
            nok=$(( nok + 1 ))
            OK_LINES+=("$name: $status") ;;
        *)
            if [[ -n "$detail" ]]; then
                PROBLEM_LINES+=("$name: $status ($detail)")
            else
                PROBLEM_LINES+=("$name: $status")
            fi ;;
    esac
done <<< "$components"

problems="$(printf '%s; ' "${PROBLEM_LINES[@]}")"
problems="${problems%; }"

# Severity is driven by the app's own overall status (the app decides what's
# critical vs degraded); components provide the detail lines.
case "$overall" in
    ok)
        exit_code="$EXIT_OK"
        summary="OK: Django healthy - ${nok}/${ntotal} components OK" ;;
    degraded)
        if [[ "$DEGRADED_LEVEL" == "ok" ]]; then
            exit_code="$EXIT_OK"
            summary="OK: Django degraded (ignored)${problems:+ - $problems}"
        else
            exit_code="$EXIT_WARNING"
            summary="WARNING: Django degraded${problems:+ - $problems}"
        fi ;;
    fail)
        exit_code="$EXIT_CRITICAL"
        summary="CRITICAL: Django fail${problems:+ - $problems}" ;;
    *)
        print_msg "UNKNOWN: Unexpected overall status '$overall' from $URL (HTTP $http_code)"
        exit "$EXIT_UNKNOWN" ;;
esac

output_lines=("$summary")
if [[ "$SHORT_MODE" -ne 1 && ${#OK_LINES[@]} -gt 0 ]]; then
    for line in "${OK_LINES[@]}"; do
        output_lines+=("OK: $line")
    done
fi

out=$(printf '%s\n' "${output_lines[@]}")
print_msg "$out"
exit "$exit_code"
