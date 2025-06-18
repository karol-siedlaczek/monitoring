#!/bin/bash

WARNING=80
CRITICAL=90

conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
conntrack_usage=$((conntrack_count*100/conntrack_max))

if [[ $conntrack_usage -ge $CRITICAL ]]
then
  echo -e "CRITICAL: conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max} (>${CRITICAL}%)"
  exit 2
elif [[ $conntrack_usage -ge $WARNING ]]
then
  echo -e "WARNING: conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max} (>${WARN}%)"
  exit 1
elif [[ $conntrack_usage -lt $WARNING ]]
then
  echo -e "OK: conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max}"
  exit 0
else
  echo -e "ERROR: unknown error"
  exit 3
fi
