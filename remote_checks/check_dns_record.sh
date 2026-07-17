#!/usr/bin/env bash
# check_dns_record.sh - verify a DNS record exists / matches an expected pattern.
# Nagios plugin. Requires `dig` (bind9-dnsutils).
set -u

PROG=$(basename "$0")
OK=0; CRITICAL=2; UNKNOWN=3

query=""; rtype=""; expect=""; server=""

usage() {
    echo "Usage: $PROG -q <name> -t <A|MX|TXT|PTR> [-e <regex>] [-s <dns-server>] [-n]"
}

while getopts "q:t:e:s:nh" opt; do
    case "$opt" in
        q) query="$OPTARG" ;;
        t) rtype=$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
        e) expect="$OPTARG" ;;
        s) server="$OPTARG" ;;
        n) : ;;                 # always nagios output; accepted for convention
        h) usage; exit "$UNKNOWN" ;;
        *) usage; exit "$UNKNOWN" ;;
    esac
done

if [ -z "$query" ] || [ -z "$rtype" ]; then usage; exit "$UNKNOWN"; fi
command -v dig >/dev/null 2>&1 || { echo "DNS UNKNOWN - dig not found"; exit "$UNKNOWN"; }

digsrv=""
[ -n "$server" ] && digsrv="@$server"

case "$rtype" in
    PTR)
        ip=$(dig +short $digsrv A "$query" 2>/dev/null | grep -Eom1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        [ -z "$ip" ] && { echo "DNS CRITICAL - $query has no A record to reverse"; exit "$CRITICAL"; }
        answer=$(dig +short $digsrv -x "$ip" 2>/dev/null | sed 's/\.$//')
        target="$ip"
        ;;
    A|MX|TXT)
        answer=$(dig +short $digsrv "$rtype" "$query" 2>/dev/null | sed 's/^"//; s/"$//; s/\.$//')
        target="$query"
        ;;
    *)
        echo "DNS UNKNOWN - unsupported type $rtype"; exit "$UNKNOWN"
        ;;
esac

if [ -z "$answer" ]; then
    echo "DNS CRITICAL - no $rtype record for $target"; exit "$CRITICAL"
fi

oneline=$(echo "$answer" | tr '\n' ' ' | sed 's/ *$//')

if [ -n "$expect" ]; then
    if echo "$answer" | grep -qiE "$expect"; then
        echo "DNS OK - $rtype $target matches '$expect' ($oneline)"; exit "$OK"
    fi
    echo "DNS CRITICAL - $rtype $target does not match '$expect' ($oneline)"; exit "$CRITICAL"
fi

echo "DNS OK - $rtype $target -> $oneline"; exit "$OK"
