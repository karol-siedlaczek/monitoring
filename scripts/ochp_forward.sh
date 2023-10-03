#!/bin/bash

PATH=/usr/bin:/bin:/usr/sbin

MNGMT_STATION=$1
HOSTNAME=$2
STATE=$3
OUTPUT=$4

if [[ -z "$MNGMT_STATION" || -z "$HOSTNAME" || -z "$STATE" || -z "$OUTPUT" ]]
then
   echo -e "Syntax error\nUsage: $0 <MNGMT_STATION> <HOSTNAME> <STATE> <OUTPUT>"
   exit 0
fi

CODE=3
case "$STATE" in
        "OK")           CODE=0 ;;
        "WARNING")      CODE=1 ;;
        "CRITICAL")     CODE=2 ;;
esac

echo -e "[P4]$HOSTNAME\t$STATE\t$OUTPUT" | send_nsca -H $MNGMT_STATION

