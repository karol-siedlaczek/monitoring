#!/bin/bash

# Karol Siedlaczek 2026
# Companion monitoring script for cert-hub application

STATUS_FILE=""
MAX_AGE=""

unknown() {
    echo "ERROR: $1"
    exit 3
}

usage() {
    echo "Usage: $0 [-m <max_age> -f <status_file>]"
    echo ""
    echo "Check certhub sync status from $STATUS_FILE"
    echo ""
    echo "  -m <max_age>      Warn if last sync ('.timestamp') is older than this"
    echo "                    (suffixes: s, m, h, d; e.g. 48h, 30m, 2d)"
    echo "  -f <status_file>  Status file produced by 'certhub cert sync' command with --status-file flag"
    exit 3
}

to_seconds() {
    local value=$1
    local number=${value%[smhd]}
    local suffix=${value:${#number}}
    [[ "$number" =~ ^[0-9]+$ ]] || return 1
    case "$suffix" in
        ""|s) echo "$number";;
        m) echo $((number * 60));;
        h) echo $((number * 3600));;
        d) echo $((number * 86400));;
        *) return 1;;
    esac
}

while getopts m:f:h flag; do
    case "${flag}" in
        m) MAX_AGE=${OPTARG};;
        f) STATUS_FILE=${OPTARG};;
        *) usage;;
    esac
done

if [[ -z "$STATUS_FILE" ]]; then
    unknown "Status file not defined (-f)"
fi

[ -r "$STATUS_FILE" ] || unknown "Cannot read $STATUS_FILE"

content=$(cat "$STATUS_FILE")
jq -e . >/dev/null 2>&1 <<<"$content" || unknown "$STATUS_FILE is not valid JSON"

exit_code=$(jq -e '.exit_code' <<<"$content" 2>/dev/null) || unknown "Missing 'exit_code' in $STATUS_FILE"
msg=$(jq -er '.msg' <<<"$content" 2>/dev/null) || unknown "Missing 'msg' in $STATUS_FILE"

if [ -n "$MAX_AGE" ]; then
    max_age_seconds=$(to_seconds "$MAX_AGE") || unknown "Invalid -m value '$MAX_AGE' (use e.g. 48h, 30m, 2d)"
    timestamp=$(jq -er '.timestamp' <<<"$content" 2>/dev/null) || unknown "Missing 'timestamp' in $STATUS_FILE"

    if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        ts_epoch=$timestamp
    else
        ts_epoch=$(date -d "$timestamp" +%s 2>/dev/null) || unknown "Cannot parse timestamp '$timestamp'"
    fi

    age=$(( $(date +%s) - ts_epoch ))
    if [ "$age" -gt "$max_age_seconds" ]; then
        msg="WARNING: Last sync at $timestamp is older than $MAX_AGE, last msg - '$msg'"
        # don't downgrade an already-failing sync result to a mere warning
        [ "$exit_code" -lt 1 ] && exit_code=1
    fi
fi

echo "$msg"
exit "$exit_code"
