#!/usr/bin/env bash
#
# Nagios plugin for HAProxy backend health.
# Queries haproxy stats via unix socket or HTTP URL (CSV format) and reports
# per-backend status with configurable per-backend thresholds.
#
# Per-backend severity:
#   CRITICAL  up_count < required (backend DOWN when up_count == 0)
#   WARNING   up_count >= required, but some servers in MAINT/DRAIN/NOLB/unknown
#   OK        up_count >= required, no servers in MAINT/DRAIN/NOLB
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") (-S <socket> | -u <url>) [options]

Options:
  -S, --socket PATH        HAProxy admin unix socket (e.g. /var/run/haproxy.sock)
  -u, --url URL            HAProxy stats URL; ';csv' is appended automatically
  -U, --user USER          Basic auth user (URL mode, optional)
  -P, --password PASS      Basic auth password (URL mode, optional)
  -b, --backend SPEC       Per-backend threshold override: <name_or_regex>:<N|all>.
                           Comma-separated list and/or repeatable flag. The part
                           before ':' is an anchored regex; first matching spec
                           wins. All backends are always checked (after applying
                           --exclude); backends not matched by any spec use the
                           default 'all UP'. If a spec matches no backends, the
                           script exits UNKNOWN.
  -e, --exclude REGEX      Exclude backends matching the anchored regex from the
                           check entirely. Comma-separated list and/or repeatable
                           flag. If a pattern matches no backends or all backends
                           would be excluded, the script exits UNKNOWN.
  -s, --short              Short output: 'OK: All backends up' for OK; only problem
                           backends for WARNING/CRITICAL. Without -s, all backends
                           are listed (including OK ones) regardless of overall status.
  -n, --nagios             Use <br/> instead of newlines (Nagios web UI)
  -t, --timeout SECONDS    Stats fetch timeout (default 10)
  -h, --help               Show this help

Examples:
  # Check all backends via unix socket (every server must be UP)
  $(basename "$0") -S /var/run/haproxy.sock

  # Check all backends via HTTP stats with basic auth
  $(basename "$0") -u http://haproxy:8404/stats -U admin -P secret

  # One backend with custom threshold; rest checked normally (all UP)
  $(basename "$0") -u http://haproxy:8404/stats -b 'be_java_app:1'

  # Multiple backends in one flag (comma-separated)
  $(basename "$0") -u http://haproxy:8404/stats -b 'be_java_app:1,be_db:all,be_web:2'

  # Same as above but with repeatable flag (back-compat form)
  $(basename "$0") -u http://haproxy:8404/stats \\
      -b 'be_java_app:1' -b 'be_db:all' -b 'be_web:2'

  # Mixed forms — comma-separated and repeatable can be combined
  $(basename "$0") -u http://haproxy:8404/stats \\
      -b 'be_java_.*:1,be_db:all' -b 'be_web:2'

  # Regex matching multiple backends (every backend matching gets threshold 1)
  $(basename "$0") -u http://haproxy:8404/stats -b 'be_(java|node|python)_.*:1'

  # Exclude legacy and internal backends from the check entirely
  $(basename "$0") -u http://haproxy:8404/stats -e 'be_legacy_.*,be_internal_.*'

  # Real-world combo: exclude noise, override critical backends, short output
  $(basename "$0") -u http://haproxy:8404/stats \\
      -b 'be_java_.*:1,be_db:all' \\
      -e 'be_legacy_.*,be_internal_.*' \\
      -s -n

  # Whitespace around commas is allowed
  $(basename "$0") -u http://haproxy:8404/stats -b 'be_app:1, be_db:all'

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

SOCKET=""
URL=""
USER_NAME=""
PASSWORD=""
SHORT_MODE=0
NAGIOS_MODE=0
TIMEOUT=10
BACKEND_SPECS=()
EXCLUDE_PATTERNS=()

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
        -S|--socket)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            SOCKET="$2"; shift 2 ;;
        -u|--url)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            URL="$2"; shift 2 ;;
        -U|--user)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            USER_NAME="$2"; shift 2 ;;
        -P|--password)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PASSWORD="$2"; shift 2 ;;
        -b|--backend)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into BACKEND_SPECS "$2"; shift 2 ;;
        -e|--exclude)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into EXCLUDE_PATTERNS "$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
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

if [[ -n "$SOCKET" && -n "$URL" ]]; then
    print_msg "UNKNOWN: --socket and --url are mutually exclusive"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$SOCKET" && -z "$URL" ]]; then
    print_msg "UNKNOWN: Either --socket or --url is required"
    usage >&2
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi

SPEC_PATTERNS=()
SPEC_REQUIRED=()
if [[ ${#BACKEND_SPECS[@]} -gt 0 ]]; then
    for spec in "${BACKEND_SPECS[@]}"; do
        if [[ ! "$spec" =~ ^(.+):(all|[1-9][0-9]*)$ ]]; then
            print_msg "UNKNOWN: Invalid -b/--backend spec '$spec' (expected NAME_OR_REGEX:N|all)"
            exit "$EXIT_UNKNOWN"
        fi
        SPEC_PATTERNS+=("${BASH_REMATCH[1]}")
        SPEC_REQUIRED+=("${BASH_REMATCH[2]}")
    done
fi

need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $1"
        exit "$EXIT_UNKNOWN"
    fi
}
if [[ -n "$SOCKET" ]]; then
    need_tool socat
else
    need_tool curl
fi

csv_file=$(mktemp)
trap 'rm -f "$csv_file"' EXIT

if [[ -n "$SOCKET" ]]; then
    if [[ ! -S "$SOCKET" ]]; then
        print_msg "UNKNOWN: Socket not found or not a socket: $SOCKET"
        exit "$EXIT_UNKNOWN"
    fi
    printf 'show stat\n' | socat -t "$TIMEOUT" - "UNIX-CONNECT:$SOCKET" >"$csv_file" 2>/dev/null || {
        print_msg "UNKNOWN: Failed to query haproxy via socket $SOCKET"
        exit "$EXIT_UNKNOWN"
    }
else
    target="${URL%;csv};csv"
    auth_args=()
    if [[ -n "$USER_NAME" ]]; then
        auth_args+=(-u "${USER_NAME}:${PASSWORD}")
    fi
    curl -fsS -m "$TIMEOUT" "${auth_args[@]}" -o "$csv_file" "$target" 2>/dev/null || {
        print_msg "UNKNOWN: Failed to fetch stats from $target"
        exit "$EXIT_UNKNOWN"
    }
fi

if [[ ! -s "$csv_file" ]]; then
    print_msg "UNKNOWN: Empty response from haproxy stats"
    exit "$EXIT_UNKNOWN"
fi

declare -A UP_COUNT
declare -A DOWN_COUNT
declare -A MAINT_COUNT
declare -A TOTAL_COUNT
declare -A UNKNOWN_STATUS
BACKENDS_SEEN=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    IFS=',' read -ra fields <<< "$line"

    row_type="${fields[32]:-}"
    [[ "$row_type" != "2" ]] && continue

    pxname="${fields[0]}"
    svname="${fields[1]}"
    status="${fields[17]}"

    [[ -z "$pxname" ]] && continue
    [[ "$svname" == "BACKEND" || "$svname" == "FRONTEND" ]] && continue

    if [[ -z "${TOTAL_COUNT[$pxname]:-}" ]]; then
        BACKENDS_SEEN+=("$pxname")
        TOTAL_COUNT[$pxname]=0
        UP_COUNT[$pxname]=0
        DOWN_COUNT[$pxname]=0
        MAINT_COUNT[$pxname]=0
    fi
    TOTAL_COUNT[$pxname]=$(( TOTAL_COUNT[$pxname] + 1 ))

    first_word="${status%% *}"
    case "$first_word" in
        UP|no)
            UP_COUNT[$pxname]=$(( UP_COUNT[$pxname] + 1 ))
            ;;
        DOWN)
            DOWN_COUNT[$pxname]=$(( DOWN_COUNT[$pxname] + 1 ))
            ;;
        MAINT|DRAIN|NOLB)
            MAINT_COUNT[$pxname]=$(( MAINT_COUNT[$pxname] + 1 ))
            ;;
        *)
            MAINT_COUNT[$pxname]=$(( MAINT_COUNT[$pxname] + 1 ))
            UNKNOWN_STATUS[$pxname]="$status"
            ;;
    esac
done < "$csv_file"

if [[ ${#BACKENDS_SEEN[@]} -eq 0 ]]; then
    print_msg "UNKNOWN: No backends found in haproxy stats"
    exit "$EXIT_UNKNOWN"
fi

declare -A EXCLUDED
declare -A EXCLUDE_MATCHED
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    for backend in "${BACKENDS_SEEN[@]}"; do
        for ((i=0; i<${#EXCLUDE_PATTERNS[@]}; i++)); do
            pattern="${EXCLUDE_PATTERNS[$i]}"
            if [[ "$backend" =~ ^${pattern}$ ]]; then
                EXCLUDED[$backend]=1
                EXCLUDE_MATCHED[$i]=1
                break
            fi
        done
    done
    for ((i=0; i<${#EXCLUDE_PATTERNS[@]}; i++)); do
        if [[ -z "${EXCLUDE_MATCHED[$i]:-}" ]]; then
            print_msg "UNKNOWN: --exclude pattern '${EXCLUDE_PATTERNS[$i]}' matched no backends"
            exit "$EXIT_UNKNOWN"
        fi
    done
fi

declare -A REQUIRED
declare -A REQUIRED_EXPLICIT
declare -A SPEC_MATCHED
for backend in "${BACKENDS_SEEN[@]}"; do
    [[ -n "${EXCLUDED[$backend]:-}" ]] && continue
    total="${TOTAL_COUNT[$backend]}"
    REQUIRED[$backend]="$total"
    if [[ ${#SPEC_PATTERNS[@]} -gt 0 ]]; then
        for ((i=0; i<${#SPEC_PATTERNS[@]}; i++)); do
            pattern="${SPEC_PATTERNS[$i]}"
            req="${SPEC_REQUIRED[$i]}"
            if [[ "$backend" =~ ^${pattern}$ ]]; then
                if [[ "$req" == "all" ]]; then
                    REQUIRED[$backend]="$total"
                elif (( req > total )); then
                    REQUIRED[$backend]="$total"
                    REQUIRED_EXPLICIT[$backend]=1
                else
                    REQUIRED[$backend]="$req"
                    REQUIRED_EXPLICIT[$backend]=1
                fi
                SPEC_MATCHED[$i]=1
                break
            fi
        done
    fi
done

CHECKED_BACKENDS=()
for backend in "${BACKENDS_SEEN[@]}"; do
    if [[ -z "${EXCLUDED[$backend]:-}" ]]; then
        CHECKED_BACKENDS+=("$backend")
    fi
done

if [[ ${#CHECKED_BACKENDS[@]} -eq 0 ]]; then
    print_msg "UNKNOWN: All backends excluded by --exclude patterns"
    exit "$EXIT_UNKNOWN"
fi

for ((i=0; i<${#SPEC_PATTERNS[@]}; i++)); do
    if [[ -z "${SPEC_MATCHED[$i]:-}" ]]; then
        print_msg "UNKNOWN: --backend pattern '${SPEC_PATTERNS[$i]}' matched no backends"
        exit "$EXIT_UNKNOWN"
    fi
done

CRIT_LINES=()
WARN_LINES=()
OK_LINES=()

for backend in "${CHECKED_BACKENDS[@]}"; do
    up="${UP_COUNT[$backend]}"
    maint="${MAINT_COUNT[$backend]}"
    total="${TOTAL_COUNT[$backend]}"
    required="${REQUIRED[$backend]}"
    unknown_status="${UNKNOWN_STATUS[$backend]:-}"

    if [[ "${REQUIRED_EXPLICIT[$backend]:-0}" == "1" ]]; then
        req_suffix=", required $required"
    else
        req_suffix=""
    fi

    if (( up < required )); then
        if (( up == 0 )); then
            CRIT_LINES+=("CRITICAL: $backend is DOWN ($up/$total up$req_suffix)")
        else
            CRIT_LINES+=("CRITICAL: $backend has DOWN servers ($up/$total up$req_suffix)")
        fi
    elif (( maint > 0 )); then
        if [[ -n "$unknown_status" ]]; then
            WARN_LINES+=("WARNING: $backend has unknown server status (status='$unknown_status', $up/$total up)")
        else
            WARN_LINES+=("WARNING: $backend has servers in maintenance ($up/$total up, $maint maint)")
        fi
    else
        OK_LINES+=("OK: $backend ($up/$total up)")
    fi
done

exit_code="$EXIT_OK"
if [[ ${#CRIT_LINES[@]} -gt 0 ]]; then
    exit_code="$EXIT_CRITICAL"
elif [[ ${#WARN_LINES[@]} -gt 0 ]]; then
    exit_code="$EXIT_WARNING"
fi

output_lines=()
if [[ "$exit_code" -eq "$EXIT_OK" ]]; then
    if [[ "$SHORT_MODE" -eq 1 ]]; then
        output_lines+=("OK: All backends up")
    else
        output_lines+=("${OK_LINES[@]}")
    fi
else
    [[ ${#CRIT_LINES[@]} -gt 0 ]] && output_lines+=("${CRIT_LINES[@]}")
    [[ ${#WARN_LINES[@]} -gt 0 ]] && output_lines+=("${WARN_LINES[@]}")
    if [[ "$SHORT_MODE" -ne 1 && ${#OK_LINES[@]} -gt 0 ]]; then
        output_lines+=("${OK_LINES[@]}")
    fi
fi
out=$(printf '%s\n' "${output_lines[@]}")
print_msg "$out"

exit "$exit_code"
