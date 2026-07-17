#!/usr/bin/env bash
# check_rbl.sh - check an IP/host against DNS blocklists. Nagios plugin. Requires `dig`.
# NOTE: public RBL mirrors may rate-limit queries from large/public resolvers;
# 127.255.255.x answers are treated as query errors, not listings. If you hit
# this, point -s (via the resolver) at the mail-server's unbound or a DQS key.
set -u

PROG=$(basename "$0")
OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

host=""; zones="zen.spamhaus.org,bl.spamcop.net,b.barracudacentral.org"
warn=1; crit=2

usage() { echo "Usage: $PROG -H <host-or-ip> [-l zone1,zone2,...] [-w N] [-c N] [-n]"; }

while getopts "H:l:w:c:nh" opt; do
    case "$opt" in
        H) host="$OPTARG" ;;
        l) zones="$OPTARG" ;;
        w) warn="$OPTARG" ;;
        c) crit="$OPTARG" ;;
        n) : ;;
        h) usage; exit "$UNKNOWN" ;;
        *) usage; exit "$UNKNOWN" ;;
    esac
done

[ -z "$host" ] && { usage; exit "$UNKNOWN"; }
command -v dig >/dev/null 2>&1 || { echo "RBL UNKNOWN - dig not found"; exit "$UNKNOWN"; }

if echo "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ip="$host"
else
    ip=$(dig +short A "$host" 2>/dev/null | grep -Eom1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
fi
[ -z "$ip" ] && { echo "RBL UNKNOWN - cannot resolve $host to an IPv4 address"; exit "$UNKNOWN"; }

IFS=. read -r a b c d <<< "$ip"
rev="$d.$c.$b.$a"

listed=""; errors=""; nzones=0
for z in $(echo "$zones" | tr ',' ' '); do
    nzones=$((nzones + 1))
    ans=$(dig +short A "$rev.$z" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        errors="$errors $z"
    elif [ -z "$ans" ]; then
        continue
    elif echo "$ans" | grep -Eq '^127\.255\.255\.'; then
        errors="$errors $z"
    elif echo "$ans" | grep -Eq '^127\.'; then
        listed="$listed $z"
    fi
done

count=$(echo $listed | wc -w | tr -d ' ')
listed=$(echo $listed | sed 's/^ *//')
errors=$(echo $errors | sed 's/^ *//')

nerr=$(echo $errors | wc -w | tr -d ' ')
if [ "$nerr" -ge "$nzones" ] && [ "$count" -eq 0 ]; then
    echo "RBL UNKNOWN - could not query any blocklist zone: $errors"; exit "$UNKNOWN"
fi

if [ "$count" -ge "$crit" ]; then
    echo "RBL CRITICAL - $ip listed on $count zone(s): $listed${errors:+ (query error: $errors)}"; exit "$CRITICAL"
elif [ "$count" -ge "$warn" ]; then
    echo "RBL WARNING - $ip listed on $count zone(s): $listed${errors:+ (query error: $errors)}"; exit "$WARNING"
fi
echo "RBL OK - $ip not listed${errors:+ (query error: $errors)}"; exit "$OK"
