#!/bin/bash

PATH=/usr/bin:/bin:/usr/sbin

MNGMT_STATION=$1
HOSTNAME=$2
SERVICE=$3
STATE=$4
OUTPUT=$5

if [[ -z "$MNGMT_STATION" || -z "$HOSTNAME" || -z "$SERVICE" || -z "$STATE" || -z "$OUTPUT" ]]
then
   echo -e "Syntax error\nUsage: $0 <MNGMT_STATION> <HOSTNAME> <SERVICE> <STATE> <OUTPUT>"
   exit 0
fi

CODE=3
case "$STATE" in
        "OK")           CODE=0 ;;
        "WARNING")      CODE=1 ;;
        "CRITICAL")     CODE=2 ;;
esac

echo -e "[P4]$HOSTNAME\t$SERVICE\t$CODE\t$OUTPUT" | send_nsca -H $MNGMT_STATION
