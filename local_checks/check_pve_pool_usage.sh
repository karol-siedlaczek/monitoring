#!/bin/bash
#
# check_proxmox_pools.sh - checks Proxmox storage pool usage against thresholds
#
# Exit codes (Nagios convention):
#   0 - OK
#   1 - WARNING
#   2 - CRITICAL
#   3 - UNKNOWN

set -u

WARNING=""
CRITICAL=""
NAGIOS=0

usage() {
    cat <<EOF
Usage: $0 -w <warning%> -c <critical%> [-n|--nagios]

Options:
  -w, --warning   Warning threshold (usage percentage, e.g. 80)
  -c, --critical  Critical threshold (usage percentage, e.g. 90)
  -n, --nagios    Replace newlines with </br> (HTML output for Nagios)
  -h, --help      Show this help
EOF
    exit 3
}

while [ $# -gt 0 ]; do
    case "$1" in
        -w|--warning)  WARNING="${2:-}"; shift 2 ;;
        -c|--critical) CRITICAL="${2:-}"; shift 2 ;;
        -n|--nagios)   NAGIOS=1; shift ;;
        -h|--help)     usage ;;
        *) echo "UNKNOWN: nieznana opcja: $1" >&2; usage ;;
    esac
done

if [ -z "$WARNING" ] || [ -z "$CRITICAL" ]; then
    echo "UNKNOWN: missing -w or -c"
    exit 3
fi

if ! [[ "$WARNING" =~ ^[0-9]+$ ]] || ! [[ "$CRITICAL" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: thresholds must be integers"
    exit 3
fi

if [ "$WARNING" -ge "$CRITICAL" ]; then
    echo "UNKNOWN: -w ($WARNING) must be lower than -c ($CRITICAL)"
    exit 3
fi

if ! command -v pvesm >/dev/null 2>&1; then
    echo "UNKNOWN: 'pvesm' command not found (is this a Proxmox host?)"
    exit 3
fi

human_size() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB PB", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%dB", b
        else        printf "%.2f%s", b, u[i]
    }'
}

raw=$(pvesm status 2>/dev/null)
if [ -z "$raw" ]; then
    echo "UNKNOWN: 'pvesm status' returned no output"
    exit 3
fi

if [ "$NAGIOS" -eq 1 ]; then
    NL="</br>"
else
    NL=$'\n'
fi

crit_lines=""
warn_lines=""
crit_count=0
warn_count=0
total_pools=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        Name*) continue ;;
    esac

    name=$(awk '{print $1}' <<<"$line")
    status=$(awk '{print $3}' <<<"$line")
    total_kb=$(awk '{print $4}' <<<"$line")
    used_kb=$(awk '{print $5}' <<<"$line")

    [ "$status" != "active" ] && continue
    [[ ! "$total_kb" =~ ^[0-9]+$ ]] && continue
    [[ ! "$used_kb"  =~ ^[0-9]+$ ]] && continue
    [ "$total_kb" -eq 0 ] && continue

    total_pools=$((total_pools + 1))
    pct=$(( used_kb * 100 / total_kb ))
    total_bytes=$(( total_kb * 1024 ))
    used_bytes=$(( used_kb  * 1024 ))

    used_h=$(human_size "$used_bytes")
    total_h=$(human_size "$total_bytes")

    if [ "$pct" -ge "$CRITICAL" ]; then
        crit_lines+="CRITICAL: Pool '${name}' utilization is ${pct}% ${used_h}/${total_h} (>${CRITICAL}%)${NL}"
        crit_count=$((crit_count + 1))
    elif [ "$pct" -ge "$WARNING" ]; then
        warn_lines+="WARNING: Pool '${name}' utilization is ${pct}% ${used_h}/${total_h} (>${WARNING}%)${NL}"
        warn_count=$((warn_count + 1))
    fi
done <<<"$raw"

if [ "$crit_count" -gt 0 ] || [ "$warn_count" -gt 0 ]; then
    combined="${crit_lines}${warn_lines}"
    combined="${combined%${NL}}"
    printf '%s' "$combined"
    [ "$NAGIOS" -eq 0 ] && printf '\n'
    [ "$crit_count" -gt 0 ] && exit 2
    exit 1
fi

echo "OK: ${total_pools} pools checked, all below thresholds (<${WARNING}%)"
exit 0
