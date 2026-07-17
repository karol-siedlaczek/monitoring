#!/bin/bash

# Karol Siedlaczek 2024

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3

WARNING=80
CRITICAL=90

usage() {
  echo "Usage: $0 [-w WARNING] [-c CRITICAL]"
  echo "  -w WARNING   Warning threshold in percent (default: 80)"
  echo "  -c CRITICAL  Critical threshold in percent (default: 90)"
  exit $NAGIOS_UNKNOWN
}

while getopts "w:c:h" opt; do
  case $opt in
    w) WARNING=$OPTARG ;;
    c) CRITICAL=$OPTARG ;;
    h) usage ;;
    *) usage ;;
  esac
done

if ! [[ $WARNING =~ ^[0-9]+$ ]] || ! [[ $CRITICAL =~ ^[0-9]+$ ]]; then
  echo "ERROR: Thresholds must be integers"
  exit $NAGIOS_UNKNOWN
fi

if [[ $WARNING -ge $CRITICAL ]]; then
  echo "ERROR: Warning threshold (${WARNING}) must be lower than critical threshold (${CRITICAL})"
  exit $NAGIOS_UNKNOWN
fi

conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
conntrack_usage=$((conntrack_count*100/conntrack_max))

if [[ $conntrack_usage -ge $CRITICAL ]]
then
  echo -e "CRITICAL: Conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max} (>${CRITICAL}%)"
  exit $NAGIOS_CRIT
elif [[ $conntrack_usage -ge $WARNING ]]
then
  echo -e "WARNING: Conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max} (>${WARNING}%)"
  exit $NAGIOS_WARN
elif [[ $conntrack_usage -lt $WARNING ]]
then
  echo -e "OK: Conntrack usage ${conntrack_usage}% ${conntrack_count}/${conntrack_max}"
  exit $NAGIOS_OK
else
  echo -e "ERROR: Unknown error"
  exit $NAGIOS_UNKNOWN
fi
