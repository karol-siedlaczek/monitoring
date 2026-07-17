#!/usr/bin/env bash
#
# Nagios plugin for BMC health via native IPMI (ipmitool over LAN).
# Vendor-agnostic — reads standard IPMI sensors, so it works on Supermicro,
# Dell iDRAC, HPE iLO and anything else speaking RMCP+ (lanplus). Pure bash +
# ipmitool, no Redfish/HTTP. Companion to check_bmc_redfish.sh for boxes whose
# BMC only exposes IPMI (or where IPMI is faster/more reliable than Redfish).
#
# Per-check severity (computed independently for each selected check):
#   CRITICAL  any sensor reporting cr/nr (critical / non-recoverable), or a
#             fetch error talking to the BMC
#   WARNING   any sensor reporting nc (non-critical) or an unknown status
#   OK        every present sensor reports ok
# Sensors with status ns/na (not present / no reading) are treated as absent
# and skipped.
#
# Overall exit code = max severity across selected checks.
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

ALL_CHECKS=(fan temp volt current ps power sel)

usage() {
    cat <<EOF
Usage (remote/LAN): $(basename "$0") -H <host> [-u USER -p PASS] [options]
       (local/KCS): $(basename "$0") -I open [options]

Options:
  -H, --host HOST            BMC IP / FQDN (required for lan/lanplus)
  -u, --user USER            BMC user (fallback: \$BMC_USER)
  -p, --password PASS        BMC password (fallback: \$BMC_PASSWORD)
                             Passed to ipmitool via \$IPMI_PASSWORD (-E),
                             not on the command line (not visible in ps).
  -i, --include LIST         Anchored regex(es) matched against check names.
                             Comma-separated and/or repeatable. Default: all.
                             A pattern that matches no check -> UNKNOWN.
  -e, --exclude LIST         Same form as --include; subtracts from the set.
                             Pattern matches no check, or empty result -> UNKNOWN.
  -s, --short                Short output: 'OK: All IPMI checks healthy' for
                             overall OK; only problem checks for WARN/CRIT.
                             Without -s all checks are listed (one line each).
  -n, --nagios               Use <br/> instead of newlines (Nagios web UI).
  -T, --timeout SEC          Per-ipmitool-call timeout (default 10)
  -I, --interface IFACE      ipmitool interface (default lanplus). Use a local
                             interface (open|openipmi|imb|bmc|lipmi|free) to
                             query the host's own BMC via KCS -- no -H/-u/-p
                             needed (avoids the shared-NIC host->own-BMC dead
                             spot). lan/lanplus = remote, require -H + creds.
  -L, --level LEVEL          Privilege level (CALLBACK|USER|OPERATOR|ADMINISTRATOR)
  -C, --cipher SUITE         RMCP+ cipher suite (e.g. 3 or 17)
      --port PORT            RMCP UDP port (default 623)
  -h, --help                 Show this help

Available check names (for --include / --exclude):
  ${ALL_CHECKS[*]}

Examples:
  # All checks, env-vars for creds
  BMC_USER=ADMIN BMC_PASSWORD=secret \\
    $(basename "$0") -H 10.0.0.10

  # Only PSU and power draw
  $(basename "$0") -H 10.0.0.10 -u ADMIN -p secret -i 'ps,power'

  # Everything except the system event log
  $(basename "$0") -H 10.0.0.10 -u ADMIN -p secret -e sel

  # Production Nagios call (short + web mode), forcing cipher 17
  BMC_USER=ADMIN BMC_PASSWORD=... \\
    $(basename "$0") -H \$HOSTADDRESS -C 17 -s -n

  # Local check via the host's own BMC (KCS) -- no network, no creds
  $(basename "$0") -I open -i 'fan,temp,volt' -s -n

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

HOST=""
USER_NAME=""
PASSWORD=""
PORT=623
TIMEOUT=10
INTERFACE="lanplus"
LEVEL=""
CIPHER=""
SHORT_MODE=0
NAGIOS_MODE=0
INCLUDE_PATTERNS=()
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
        -H|--host)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            HOST="$2"; shift 2 ;;
        -u|--user)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            USER_NAME="$2"; shift 2 ;;
        -p|--password)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PASSWORD="$2"; shift 2 ;;
        -i|--include)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into INCLUDE_PATTERNS "$2"; shift 2 ;;
        -e|--exclude)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into EXCLUDE_PATTERNS "$2"; shift 2 ;;
        -T|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        -I|--interface)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            INTERFACE="$2"; shift 2 ;;
        -L|--level)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            LEVEL="$2"; shift 2 ;;
        -C|--cipher)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            CIPHER="$2"; shift 2 ;;
        --port)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PORT="$2"; shift 2 ;;
        -s|--short)    SHORT_MODE=1; shift ;;
        -n|--nagios)   NAGIOS_MODE=1; shift ;;
        -h|--help)     usage; exit "$EXIT_OK" ;;
        *)
            echo "UNKNOWN: Unknown argument: $1" >&2
            usage >&2
            exit "$EXIT_UNKNOWN" ;;
    esac
done

[[ -z "$USER_NAME" ]] && USER_NAME="${BMC_USER:-}"
[[ -z "$PASSWORD"  ]] && PASSWORD="${BMC_PASSWORD:-}"

# lan/lanplus talk to a remote BMC (need host + creds); anything else is a
# local ipmitool interface (open|openipmi|imb|bmc|...) hitting the host's own
# BMC over KCS -- no host/creds, and -E/-p/-C are meaningless there.
case "$INTERFACE" in
    lan|lanplus) IPMI_LOCAL=0 ;;
    *)           IPMI_LOCAL=1 ;;
esac

print_msg() {
    local msg="$1"
    if [[ "$NAGIOS_MODE" -eq 1 ]]; then
        printf '%s\n' "${msg//$'\n'/<br/>}"
    else
        printf '%s\n' "$msg"
    fi
}

if [[ "$IPMI_LOCAL" -eq 0 ]]; then
    if [[ -z "$HOST" ]]; then
        print_msg "UNKNOWN: Missing -H/--host (required for $INTERFACE)"
        usage >&2
        exit "$EXIT_UNKNOWN"
    fi
    if [[ -z "$USER_NAME" ]]; then
        print_msg "UNKNOWN: Missing BMC user (-u or \$BMC_USER)"
        exit "$EXIT_UNKNOWN"
    fi
    if [[ -z "$PASSWORD" ]]; then
        print_msg "UNKNOWN: Missing BMC password (-p or \$BMC_PASSWORD)"
        exit "$EXIT_UNKNOWN"
    fi
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --port must be a positive integer, got: '$PORT'"
    exit "$EXIT_UNKNOWN"
fi

need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $1"
        exit "$EXIT_UNKNOWN"
    fi
}
need_tool ipmitool
need_tool timeout
need_tool awk

SELECTED=()
declare -A INCLUDE_MATCHED
declare -A EXCLUDE_MATCHED

if [[ ${#INCLUDE_PATTERNS[@]} -eq 0 ]]; then
    SELECTED=("${ALL_CHECKS[@]}")
else
    for check in "${ALL_CHECKS[@]}"; do
        for ((i=0; i<${#INCLUDE_PATTERNS[@]}; i++)); do
            pattern="${INCLUDE_PATTERNS[$i]}"
            if [[ "$check" =~ ^${pattern}$ ]]; then
                SELECTED+=("$check")
                INCLUDE_MATCHED[$i]=1
                break
            fi
        done
    done
    for ((i=0; i<${#INCLUDE_PATTERNS[@]}; i++)); do
        if [[ -z "${INCLUDE_MATCHED[$i]:-}" ]]; then
            print_msg "UNKNOWN: --include pattern '${INCLUDE_PATTERNS[$i]}' matched no check"
            exit "$EXIT_UNKNOWN"
        fi
    done
fi

if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    KEEP=()
    for check in "${SELECTED[@]}"; do
        excluded=0
        for ((i=0; i<${#EXCLUDE_PATTERNS[@]}; i++)); do
            pattern="${EXCLUDE_PATTERNS[$i]}"
            if [[ "$check" =~ ^${pattern}$ ]]; then
                excluded=1
                EXCLUDE_MATCHED[$i]=1
                break
            fi
        done
        [[ $excluded -eq 0 ]] && KEEP+=("$check")
    done
    SELECTED=("${KEEP[@]}")
    for ((i=0; i<${#EXCLUDE_PATTERNS[@]}; i++)); do
        if [[ -z "${EXCLUDE_MATCHED[$i]:-}" ]]; then
            print_msg "UNKNOWN: --exclude pattern '${EXCLUDE_PATTERNS[$i]}' matched no check"
            exit "$EXIT_UNKNOWN"
        fi
    done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    print_msg "UNKNOWN: All checks excluded by --exclude patterns"
    exit "$EXIT_UNKNOWN"
fi

if [[ "$IPMI_LOCAL" -eq 1 ]]; then
    # Local KCS interface: no host, no creds, no RMCP+ cipher.
    IPMI_ARGS=(-I "$INTERFACE")
    [[ -n "$LEVEL" ]] && IPMI_ARGS+=(-L "$LEVEL")
else
    # Password goes through the environment (-E), never argv.
    export IPMI_PASSWORD="$PASSWORD"
    IPMI_ARGS=(-I "$INTERFACE" -H "$HOST" -U "$USER_NAME" -E -p "$PORT")
    [[ -n "$LEVEL"  ]] && IPMI_ARGS+=(-L "$LEVEL")
    [[ -n "$CIPHER" ]] && IPMI_ARGS+=(-C "$CIPHER")
fi

IPMI_OUT=""
IPMI_RC=0
# Run ipmitool with the connection args + given subcommand. stdout -> $IPMI_OUT,
# status -> $IPMI_RC (and return value). Must NOT be called from $(...) — the
# globals would not propagate back.
ipmi_run() {
    IPMI_OUT=$(timeout "$TIMEOUT" ipmitool "${IPMI_ARGS[@]}" "$@" 2>/dev/null)
    IPMI_RC=$?
    return $IPMI_RC
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Leading numeric value (optionally signed/decimal) of a reading like
# "23 degrees C" / "4800 RPM" / "12.096 Volts"; empty if none.
extract_num() {
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)? ]] && printf '%s' "${BASH_REMATCH[0]}"
}

# Sanitize a sensor name for a perfdata label.
sanitize() {
    local s="$1"
    s="${s// /_}"
    s="${s//[^A-Za-z0-9_.-]/_}"
    printf '%s' "$s"
}

# Map an ipmitool sdr status code to ok|warn|crit|absent.
sensor_severity() {
    case "$1" in
        ok)                       printf ok ;;
        ns|na|"")                 printf absent ;;
        nc|lnc|unc)               printf warn ;;
        cr|lcr|ucr|nr|lnr|unr)    printf crit ;;
        *)                        printf warn ;;
    esac
}

CRIT_LINES=()
WARN_LINES=()
OK_LINES=()
PERFDATA=()

# Globals populated by the sensor classifier and consumed by emit_check_line.
CI_TOTAL=0
CI_HEALTHY=0
CI_PROBLEMS=""
CI_SEVERITY="ok"

# Escalate CI_SEVERITY by one observed severity (ok < warn < crit).
ci_escalate() {
    case "$CI_SEVERITY" in
        ok)   CI_SEVERITY="$1" ;;
        warn) [[ "$1" == "crit" ]] && CI_SEVERITY="crit" ;;
    esac
}

# emit_check_line <check_name> <summary> [override_severity]
emit_check_line() {
    local check="$1" summary="$2" override="${3:-}"
    local sev="${override:-$CI_SEVERITY}"
    case "$sev" in
        ok)   OK_LINES+=("OK: $check - $summary") ;;
        warn) WARN_LINES+=("WARNING: $check - $summary${CI_PROBLEMS:+ ($CI_PROBLEMS)}") ;;
        crit) CRIT_LINES+=("CRITICAL: $check - $summary${CI_PROBLEMS:+ ($CI_PROBLEMS)}") ;;
    esac
}

emit_fetch_error() {
    local check="$1" what="$2"
    CRIT_LINES+=("CRITICAL: $check - ipmitool failed: $what (rc ${IPMI_RC:-?})")
}

# check_sensor <check_name> <ipmi_sensor_type> <perf_prefix> [scan_desc]
# Reads `ipmitool sdr type <type>` (columns: name | id | status | entity |
# reading), classifies each present sensor and accumulates perfdata. With
# scan_desc=1 (used for discrete PSU sensors) a failure keyword in the reading
# escalates an otherwise-ok sensor to CRITICAL.
check_sensor() {
    local check="$1" sdr_type="$2" prefix="$3" scan_desc="${4:-0}"
    if ! ipmi_run sdr type "$sdr_type"; then
        emit_fetch_error "$check" "sdr type '$sdr_type'"; return
    fi
    CI_TOTAL=0; CI_HEALTHY=0; CI_PROBLEMS=""; CI_SEVERITY="ok"
    local line name status reading num sev
    while IFS='|' read -r name _ status _ reading; do
        name=$(trim "$name")
        [[ -z "$name" ]] && continue
        status=$(trim "$status")
        reading=$(trim "$reading")
        sev=$(sensor_severity "$status")
        [[ "$sev" == "absent" ]] && continue
        if [[ "$scan_desc" == "1" && "$sev" == "ok" ]]; then
            shopt -s nocasematch
            [[ "$reading" =~ (fail|lost|fault|error|absent) ]] && sev="crit"
            shopt -u nocasematch
        fi
        CI_TOTAL=$(( CI_TOTAL + 1 ))
        case "$sev" in
            ok)
                CI_HEALTHY=$(( CI_HEALTHY + 1 )) ;;
            warn)
                CI_PROBLEMS+="${CI_PROBLEMS:+; }$name: ${status:-?} (${reading:-?})"
                ci_escalate warn ;;
            crit)
                CI_PROBLEMS+="${CI_PROBLEMS:+; }$name: ${status:-?} (${reading:-?})"
                ci_escalate crit ;;
        esac
        num=$(extract_num "$reading")
        [[ -n "$num" ]] && PERFDATA+=("${prefix}_$(sanitize "$name")=${num}")
    done <<< "$IPMI_OUT"
    emit_check_line "$check" "$CI_HEALTHY/$CI_TOTAL healthy"
}

# Total power draw. Prefers DCMI; falls back to summing Watts sensors. A failing
# fallback (i.e. the BMC is unreachable) is a CRITICAL fetch error; a reachable
# BMC with no power telemetry is reported OK.
check_power() {
    local watts=""
    if ipmi_run dcmi power reading; then
        watts=$(awk -F: '/Instantaneous power reading/{gsub(/[^0-9.]/,"",$2); print $2; exit}' <<< "$IPMI_OUT")
    fi
    if [[ -n "$watts" ]]; then
        PERFDATA+=("power_watts=${watts}")
        OK_LINES+=("OK: power - ${watts}W")
        return
    fi
    # DCMI unavailable -> try Watts sensors via SDR.
    if ! ipmi_run sdr type Current; then
        emit_fetch_error power "dcmi power reading / sdr type Current"; return
    fi
    local name reading num cnt=0
    while IFS='|' read -r name _ _ _ reading; do
        name=$(trim "$name"); reading=$(trim "$reading")
        [[ "$reading" == *[Ww]atts* ]] || continue
        num=$(extract_num "$reading"); [[ -z "$num" ]] && continue
        PERFDATA+=("power_$(sanitize "$name")=${num}")
        cnt=$(( cnt + 1 ))
    done <<< "$IPMI_OUT"
    if [[ $cnt -eq 0 ]]; then
        OK_LINES+=("OK: power - no power metrics available")
    else
        OK_LINES+=("OK: power - $cnt power sensor(s)")
    fi
}

# System Event Log health: WARNING on overflow (events lost) or near-full SEL.
check_sel() {
    if ! ipmi_run sel info; then
        emit_fetch_error sel "sel info"; return
    fi
    local entries pct overflow
    entries=$(awk -F: '/^Entries/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<< "$IPMI_OUT")
    pct=$(awk -F: '/Percent Used/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<< "$IPMI_OUT")
    overflow=$(awk -F: '/Overflow/{gsub(/[^a-zA-Z]/,"",$2); print tolower($2); exit}' <<< "$IPMI_OUT")
    [[ -z "$entries" ]] && entries=0
    [[ -n "$pct" ]] && PERFDATA+=("sel_pct_used=${pct};;;0;100")
    PERFDATA+=("sel_entries=${entries}")
    CI_SEVERITY="ok"; CI_PROBLEMS=""
    if [[ "$overflow" == "true" ]]; then
        CI_PROBLEMS+="${CI_PROBLEMS:+; }SEL overflow - events lost"
        ci_escalate warn
    fi
    if [[ -n "$pct" && "$pct" -ge 90 ]]; then
        CI_PROBLEMS+="${CI_PROBLEMS:+; }SEL ${pct}% full"
        ci_escalate warn
    fi
    emit_check_line sel "$entries entries${pct:+, ${pct}% used}"
}

for check in "${SELECTED[@]}"; do
    case "$check" in
        fan)     check_sensor fan     "Fan"          fan ;;
        temp)    check_sensor temp    "Temperature"  temp ;;
        volt)    check_sensor volt    "Voltage"      volt ;;
        current) check_sensor current "Current"      current ;;
        ps)      check_sensor ps      "Power Supply" psu 1 ;;
        power)   check_power ;;
        sel)     check_sel ;;
    esac
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
        output_lines+=("OK: All IPMI checks healthy")
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
# Short mode is for humans: status line only, no perfdata firehose.
if [[ "$SHORT_MODE" -ne 1 && ${#PERFDATA[@]} -gt 0 ]]; then
    out="${out} | ${PERFDATA[*]}"
fi
print_msg "$out"

exit "$exit_code"
