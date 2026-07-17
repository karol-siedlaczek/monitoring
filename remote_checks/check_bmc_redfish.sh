#!/usr/bin/env bash
#
# Nagios plugin for BMC health via Redfish API.
# Supports Supermicro IPMI, Dell iDRAC and HPE iLO. Pure bash + curl + jq —
# works on ARM64 (drop-in replacement for the x86-64-only PyInstaller binary
# nagios_supermicro_redfish).
#
# Per-check severity (computed independently for each selected check):
#   CRITICAL  any component with Status.Health == "Critical", or fetch error
#   WARNING   any component with Status.Health == "Warning" or unknown health
#   OK        every present component reports Status.Health == "OK"/null
#
# Overall exit code = max severity across selected checks.
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

ALL_CHECKS=(fan temp volt ps storage cpu memory nic gpu perf)

usage() {
    cat <<EOF
Usage: $(basename "$0") -H <host> --vendor <v> [-u USER -p PASS] [options]

Options:
  -H, --host HOST            BMC IP / FQDN (required)
  -u, --user USER            BMC user (fallback: \$BMC_USER)
  -p, --password PASS        BMC password (fallback: \$BMC_PASSWORD)
      --vendor V             Vendor: supermicro | dell | hp (required)
  -i, --include LIST         Anchored regex(es) matched against check names.
                             Comma-separated and/or repeatable. Default: all.
                             A pattern that matches no check -> UNKNOWN.
  -e, --exclude LIST         Same form as --include; subtracts from the set.
                             Pattern matches no check, or empty result -> UNKNOWN.
  -s, --short                Short output: 'OK: All BMC checks healthy' for
                             overall OK; only problem checks for WARN/CRIT.
                             Without -s all checks are listed (one line each).
  -n, --nagios               Use <br/> instead of newlines (Nagios web UI).
  -T, --timeout SEC          curl timeout per call (default 10)
  -k, --insecure             Skip TLS verify (BMC self-signed certs)
      --port PORT            HTTPS port (default 443)
  -h, --help                 Show this help

Available check names (for --include / --exclude):
  ${ALL_CHECKS[*]}

Examples:
  # All checks, env-vars for creds
  BMC_USER=ADMIN BMC_PASSWORD=secret \\
    $(basename "$0") -H 10.0.0.10 --vendor supermicro -k

  # Only PSU and power perf
  $(basename "$0") -H 10.0.0.10 -u ADMIN -p secret --vendor supermicro -k \\
    -i 'ps,perf'

  # Everything except GPU (no GPU in this box)
  $(basename "$0") -H 10.0.0.10 -u ADMIN -p secret --vendor dell -k -e gpu

  # Production Nagios call (short + web mode)
  BMC_USER=ADMIN BMC_PASSWORD=... \\
    $(basename "$0") -H \$HOSTADDRESS --vendor supermicro -k -s -n

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

HOST=""
USER_NAME=""
PASSWORD=""
VENDOR=""
PORT=443
TIMEOUT=10
INSECURE=0
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
        --vendor)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            VENDOR="$2"; shift 2 ;;
        -i|--include)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into INCLUDE_PATTERNS "$2"; shift 2 ;;
        -e|--exclude)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            split_csv_into EXCLUDE_PATTERNS "$2"; shift 2 ;;
        -T|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        --port)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PORT="$2"; shift 2 ;;
        -k|--insecure) INSECURE=1; shift ;;
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

print_msg() {
    local msg="$1"
    if [[ "$NAGIOS_MODE" -eq 1 ]]; then
        printf '%s\n' "${msg//$'\n'/<br/>}"
    else
        printf '%s\n' "$msg"
    fi
}

if [[ -z "$HOST" ]]; then
    print_msg "UNKNOWN: Missing -H/--host"
    usage >&2
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$VENDOR" ]]; then
    print_msg "UNKNOWN: Missing --vendor"
    usage >&2
    exit "$EXIT_UNKNOWN"
fi
case "$VENDOR" in
    supermicro|dell|hp) ;;
    *) print_msg "UNKNOWN: --vendor must be one of: supermicro, dell, hp (got '$VENDOR')"
       exit "$EXIT_UNKNOWN" ;;
esac
if [[ -z "$USER_NAME" ]]; then
    print_msg "UNKNOWN: Missing BMC user (-u or \$BMC_USER)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$PASSWORD" ]]; then
    print_msg "UNKNOWN: Missing BMC password (-p or \$BMC_PASSWORD)"
    exit "$EXIT_UNKNOWN"
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
need_tool curl
need_tool jq

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

case "$VENDOR" in
    dell)
        SYSTEM_ID="System.Embedded.1"
        CHASSIS_ID="System.Embedded.1" ;;
    supermicro|hp)
        SYSTEM_ID="1"
        CHASSIS_ID="1" ;;
esac
SYSTEMS_BASE="/redfish/v1/Systems/$SYSTEM_ID"
CHASSIS_BASE="/redfish/v1/Chassis/$CHASSIS_ID"

REDFISH_TMP_FILES=()
cleanup() {
    local f
    for f in "${REDFISH_TMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

REDFISH_BODY_FILE=""
REDFISH_LAST_CODE=""
REDFISH_WALK_OUT=""

# Body goes to file $REDFISH_BODY_FILE, status in $REDFISH_LAST_CODE.
# Must NOT be called from $(...) — globals would not propagate back.
# Returns: 0 = 2xx + valid JSON, 1 = transport/non-2xx, 2 = 2xx but invalid JSON.
redfish_get() {
    local path="$1"
    REDFISH_BODY_FILE=$(mktemp)
    REDFISH_TMP_FILES+=("$REDFISH_BODY_FILE")
    REDFISH_LAST_CODE=""
    local args=(-sS -m "$TIMEOUT" -u "$USER_NAME:$PASSWORD"
                -H 'Accept: application/json'
                -w '%{http_code}' -o "$REDFISH_BODY_FILE")
    [[ "$INSECURE" -eq 1 ]] && args+=(-k)
    REDFISH_LAST_CODE=$(curl "${args[@]}" "https://$HOST:$PORT$path" 2>/dev/null) || {
        REDFISH_LAST_CODE="curl_error"
        return 1
    }
    if [[ ! "$REDFISH_LAST_CODE" =~ ^2[0-9][0-9]$ ]]; then
        return 1
    fi
    if ! jq -e . "$REDFISH_BODY_FILE" >/dev/null 2>&1; then
        return 2
    fi
    return 0
}

# Walks a collection (.Members[]."@odata.id"), accumulates each member JSON
# as one compact line into $REDFISH_WALK_OUT. Must NOT be called from $(...).
# Returns 0 always when the top-level fetch succeeded (empty result if no
# members or all member fetches failed); 1 if top-level fetch failed.
redfish_walk_collection() {
    local path="$1"
    REDFISH_WALK_OUT=""
    if ! redfish_get "$path"; then
        return 1
    fi
    local -a member_paths
    mapfile -t member_paths < <(jq -r '.Members[]? | ."@odata.id" // empty' "$REDFISH_BODY_FILE")
    [[ ${#member_paths[@]} -eq 0 ]] && return 0
    local mp line
    for mp in "${member_paths[@]}"; do
        if ! redfish_get "$mp"; then continue; fi
        line=$(jq -c . "$REDFISH_BODY_FILE")
        REDFISH_WALK_OUT+="${REDFISH_WALK_OUT:+$'\n'}${line}"
    done
    return 0
}

CRIT_LINES=()
WARN_LINES=()
OK_LINES=()
PERFDATA=()

# Sanitize a sensor/component name for perfdata label.
sanitize() {
    local s="$1"
    s="${s// /_}"
    s="${s//[^A-Za-z0-9_.-]/_}"
    printf '%s' "$s"
}

# classify_items <check_name> <items_jsonl> [<unit_suffix>]
# items_jsonl: one JSON object per line, each having .Name, .Status.Health,
# .Status.State (used for messages). Returns "ok|warn|crit" counts and a
# problems string via globals: CI_HEALTHY, CI_TOTAL, CI_PROBLEMS, CI_SEVERITY.
classify_items() {
    local items="$1"
    CI_TOTAL=0; CI_HEALTHY=0
    CI_PROBLEMS=""
    CI_SEVERITY="ok"
    [[ -z "$items" ]] && return 0
    local line name health state sev
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        state=$(jq -r '.Status.State // ""' <<<"$line")
        [[ "$state" == "Absent" ]] && continue
        CI_TOTAL=$(( CI_TOTAL + 1 ))
        name=$(jq -r '.Name // .Id // "unknown"' <<<"$line")
        health=$(jq -r '.Status.Health // ""' <<<"$line")
        case "$health" in
            "OK"|"")
                CI_HEALTHY=$(( CI_HEALTHY + 1 )) ;;
            "Warning")
                sev="warn"
                CI_PROBLEMS+="${CI_PROBLEMS:+; }$name: Warning ($state)" ;;
            "Critical")
                sev="crit"
                CI_PROBLEMS+="${CI_PROBLEMS:+; }$name: Critical ($state)" ;;
            *)
                sev="warn"
                CI_PROBLEMS+="${CI_PROBLEMS:+; }$name: Unknown health '$health' ($state)" ;;
        esac
        if [[ -n "${sev:-}" ]]; then
            case "$CI_SEVERITY" in
                ok)   CI_SEVERITY="$sev" ;;
                warn) [[ "$sev" == "crit" ]] && CI_SEVERITY="crit" ;;
            esac
            sev=""
        fi
    done <<<"$items"
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
    local check="$1" path="$2"
    CRIT_LINES+=("CRITICAL: $check - failed to fetch $path (HTTP ${REDFISH_LAST_CODE:-?})")
}

check_fan() {
    if ! redfish_get "$CHASSIS_BASE/Thermal"; then
        emit_fetch_error fan "$CHASSIS_BASE/Thermal"; return
    fi
    local body items
    body=$(cat "$REDFISH_BODY_FILE")
    items=$(jq -c '.Fans[]?' <<<"$body")
    classify_items "$items"
    while IFS=$'\t' read -r name reading; do
        [[ -z "$name" || "$reading" == "null" || -z "$reading" ]] && continue
        PERFDATA+=("fan_$(sanitize "$name")=${reading}")
    done < <(jq -r '.Fans[]? | [(.Name // .FanName // .Id // "fan"), (.Reading // .ReadingRPM // "null")] | @tsv' <<<"$body")
    emit_check_line fan "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_temp() {
    if ! redfish_get "$CHASSIS_BASE/Thermal"; then
        emit_fetch_error temp "$CHASSIS_BASE/Thermal"; return
    fi
    local body items
    body=$(cat "$REDFISH_BODY_FILE")
    items=$(jq -c '.Temperatures[]?' <<<"$body")
    classify_items "$items"
    while IFS=$'\t' read -r name reading warn crit; do
        [[ -z "$name" || "$reading" == "null" || -z "$reading" ]] && continue
        [[ "$warn" == "null" ]] && warn=""
        [[ "$crit" == "null" ]] && crit=""
        PERFDATA+=("temp_$(sanitize "$name")=${reading};${warn};${crit}")
    done < <(jq -r '.Temperatures[]? | [.Name, .ReadingCelsius, (.UpperThresholdNonCritical // .UpperThresholdUser // "null"), (.UpperThresholdCritical // "null")] | @tsv' <<<"$body")
    emit_check_line temp "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_volt() {
    if ! redfish_get "$CHASSIS_BASE/Power"; then
        emit_fetch_error volt "$CHASSIS_BASE/Power"; return
    fi
    local body items
    body=$(cat "$REDFISH_BODY_FILE")
    items=$(jq -c '.Voltages[]?' <<<"$body")
    classify_items "$items"
    while IFS=$'\t' read -r name reading; do
        [[ -z "$name" || "$reading" == "null" || -z "$reading" ]] && continue
        PERFDATA+=("volt_$(sanitize "$name")=${reading}")
    done < <(jq -r '.Voltages[]? | [.Name, .ReadingVolts] | @tsv' <<<"$body")
    emit_check_line volt "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_ps() {
    if ! redfish_get "$CHASSIS_BASE/Power"; then
        emit_fetch_error ps "$CHASSIS_BASE/Power"; return
    fi
    local body items
    body=$(cat "$REDFISH_BODY_FILE")
    items=$(jq -c '.PowerSupplies[]?' <<<"$body")
    classify_items "$items"
    while IFS=$'\t' read -r name watts; do
        [[ -z "$name" || "$watts" == "null" || -z "$watts" ]] && continue
        PERFDATA+=("psu_$(sanitize "$name")_watts=${watts}")
    done < <(jq -r '.PowerSupplies[]? | [.Name, (.PowerInputWatts // .LastPowerOutputWatts // "null")] | @tsv' <<<"$body")
    emit_check_line ps "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_storage() {
    local controllers_jsonl="" drives_jsonl=""
    if ! redfish_get "$SYSTEMS_BASE/Storage"; then
        emit_fetch_error storage "$SYSTEMS_BASE/Storage"; return
    fi
    local -a member_paths
    mapfile -t member_paths < <(jq -r '.Members[]? | ."@odata.id" // empty' "$REDFISH_BODY_FILE")
    if [[ ${#member_paths[@]} -eq 0 ]]; then
        OK_LINES+=("OK: storage - no controllers present")
        return
    fi
    local mp drv_path member_body sc_inline
    for mp in "${member_paths[@]}"; do
        if ! redfish_get "$mp"; then continue; fi
        member_body=$(cat "$REDFISH_BODY_FILE")
        # StorageControllers (inline)
        sc_inline=$(jq -c '.StorageControllers[]?' <<<"$member_body")
        if [[ -n "$sc_inline" ]]; then
            controllers_jsonl+="${controllers_jsonl:+$'\n'}$sc_inline"
        fi
        # Drives are links (must fetch each)
        local -a drive_paths
        mapfile -t drive_paths < <(jq -r '.Drives[]? | ."@odata.id" // empty' <<<"$member_body")
        for drv_path in "${drive_paths[@]}"; do
            if ! redfish_get "$drv_path"; then continue; fi
            drives_jsonl+="${drives_jsonl:+$'\n'}$(jq -c . "$REDFISH_BODY_FILE")"
        done
    done
    local total_drives healthy_drives total_ctrls healthy_ctrls problems severity
    severity="ok"; problems=""
    classify_items "$controllers_jsonl"
    total_ctrls=$CI_TOTAL; healthy_ctrls=$CI_HEALTHY
    [[ -n "$CI_PROBLEMS" ]] && problems="ctrl: $CI_PROBLEMS"
    [[ "$CI_SEVERITY" != "ok" ]] && severity="$CI_SEVERITY"
    classify_items "$drives_jsonl"
    total_drives=$CI_TOTAL; healthy_drives=$CI_HEALTHY
    if [[ -n "$CI_PROBLEMS" ]]; then
        problems+="${problems:+ | }drive: $CI_PROBLEMS"
    fi
    case "$CI_SEVERITY" in
        crit) severity="crit" ;;
        warn) [[ "$severity" != "crit" ]] && severity="warn" ;;
    esac
    CI_PROBLEMS="$problems"
    emit_check_line storage "$healthy_drives/$total_drives drives + $healthy_ctrls/$total_ctrls ctrls healthy" "$severity"
}

check_collection_health() {
    # check_collection_health <check_name> <collection_path>
    local check="$1" path="$2"
    if ! redfish_walk_collection "$path"; then
        emit_fetch_error "$check" "$path"; return
    fi
    local jsonl="$REDFISH_WALK_OUT"
    classify_items "$jsonl"
    if [[ $CI_TOTAL -eq 0 ]]; then
        OK_LINES+=("OK: $check - no components present")
        return
    fi
    emit_check_line "$check" "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_cpu() {
    check_collection_health cpu "$SYSTEMS_BASE/Processors"
}

check_memory() {
    check_collection_health memory "$SYSTEMS_BASE/Memory"
}

check_nic() {
    # Prefer Chassis/NetworkAdapters; fall back to Systems/EthernetInterfaces.
    local jsonl=""
    if redfish_walk_collection "$CHASSIS_BASE/NetworkAdapters"; then
        jsonl="$REDFISH_WALK_OUT"
    fi
    if [[ -z "$jsonl" ]]; then
        if ! redfish_walk_collection "$SYSTEMS_BASE/EthernetInterfaces"; then
            emit_fetch_error nic "$SYSTEMS_BASE/EthernetInterfaces"; return
        fi
        jsonl="$REDFISH_WALK_OUT"
    fi
    classify_items "$jsonl"
    if [[ $CI_TOTAL -eq 0 ]]; then
        OK_LINES+=("OK: nic - no interfaces present")
        return
    fi
    emit_check_line nic "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_gpu() {
    if ! redfish_walk_collection "$SYSTEMS_BASE/Processors"; then
        emit_fetch_error gpu "$SYSTEMS_BASE/Processors"; return
    fi
    local jsonl="$REDFISH_WALK_OUT"
    local filtered
    filtered=$(printf '%s\n' "$jsonl" | jq -c 'select((.ProcessorType // "") == "GPU" or ((.ProcessorType // "") | ascii_downcase | contains("gpu")))')
    classify_items "$filtered"
    if [[ $CI_TOTAL -eq 0 ]]; then
        OK_LINES+=("OK: gpu - no GPU present")
        return
    fi
    emit_check_line gpu "$CI_HEALTHY/$CI_TOTAL healthy"
}

check_perf() {
    local pbody="" tbody="" power="" temp_max="" fan_avg="" fan_count=0
    local pstatus=1 tstatus=1
    if redfish_get "$CHASSIS_BASE/Power"; then
        pbody=$(cat "$REDFISH_BODY_FILE")
        pstatus=0
    fi
    if redfish_get "$CHASSIS_BASE/Thermal"; then
        tbody=$(cat "$REDFISH_BODY_FILE")
        tstatus=0
    fi
    if [[ $pstatus -ne 0 && $tstatus -ne 0 ]]; then
        emit_fetch_error perf "$CHASSIS_BASE/Power and $CHASSIS_BASE/Thermal"
        return
    fi
    if [[ $pstatus -eq 0 ]]; then
        power=$(jq -r '[.PowerControl[]?.PowerConsumedWatts // empty] | if length>0 then add else "" end' <<<"$pbody")
    fi
    if [[ $tstatus -eq 0 ]]; then
        temp_max=$(jq -r '[.Temperatures[]?.ReadingCelsius // empty] | if length>0 then max else "" end' <<<"$tbody")
        fan_count=$(jq -r '[.Fans[]? | (.Reading // .ReadingRPM // empty)] | length' <<<"$tbody")
        if [[ "$fan_count" -gt 0 ]]; then
            fan_avg=$(jq -r '[.Fans[]? | (.Reading // .ReadingRPM // empty)] | (add / length) | floor' <<<"$tbody")
        fi
    fi
    local parts=()
    [[ -n "${power:-}"    ]] && { PERFDATA+=("power_watts=${power}");      parts+=("power=${power}W"); }
    [[ -n "${temp_max:-}" ]] && { PERFDATA+=("temp_max=${temp_max}");      parts+=("temp_max=${temp_max}C"); }
    [[ -n "${fan_avg:-}"  ]] && { PERFDATA+=("fan_avg_rpm=${fan_avg}");    parts+=("fan_avg=${fan_avg}RPM"); }
    local summary="${parts[*]:-no metrics available}"
    OK_LINES+=("OK: perf - ${summary// / }")
}

for check in "${SELECTED[@]}"; do
    case "$check" in
        fan)     check_fan ;;
        temp)    check_temp ;;
        volt)    check_volt ;;
        ps)      check_ps ;;
        storage) check_storage ;;
        cpu)     check_cpu ;;
        memory)  check_memory ;;
        nic)     check_nic ;;
        gpu)     check_gpu ;;
        perf)    check_perf ;;
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
        output_lines+=("OK: All BMC checks healthy")
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
if [[ ${#PERFDATA[@]} -gt 0 ]]; then
    out="${out} | ${PERFDATA[*]}"
fi
print_msg "$out"

exit "$exit_code"
