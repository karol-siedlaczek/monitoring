#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

USER=$1
PASS=$2
WARN=$3
CRIT=$4

if [[ -z "$USER" || -z "$PASS" || -z "$WARN" || -z "$CRIT" ]]
then
   echo -e "Syntax error\nUsage: $0 <USER> <PASS> <WARN> <CRIT>"
   exit $NAGIOS_CRIT
fi

curl_output=$(curl --fail --show-error -s -u $USER:$PASS --noproxy '*' http://localhost:8787/jolokia/read/java.lang:type=Memory/HeapMemoryUsage 2>&1)
curl_exit_code=$?

if [ $curl_exit_code -gt 0 ]; then
   echo "ERROR: ${curl_output}"
   exit $NAGIOS_CRIT
fi

heap_used=$(jq .value.used <<< $curl_output)
# heap_committed=$(jq .value.committed <<< $curl_output )
heap_max=$(jq .value.max <<< $curl_output )

if [[ $heap_used == +([[:digit:]]) && $heap_max == +([[:digit:]]) ]]; then #&& $heap_committed == +([[:digit:]])
   heap_usage=$((heap_used*100 / heap_max))
   # heap_allocated=$((heap_committed*100 / heap_max))

   if [[ $heap_usage -gt $CRIT ]]; then
      MSG="CRITICAL: Heap memory usage ${heap_usage}% > ${CRIT}%"
      EXIT_CODE=$NAGIOS_CRIT
   elif [[ $heap_usage -gt $WARN ]]; then
      MSG="WARNING: Heap memory usage ${heap_usage}% > ${WARN}%"
      EXIT_CODE=$NAGIOS_WARN
   else
      MSG="OK: Heap memory usage ${heap_usage}%"
      EXIT_CODE=$NAGIOS_OK
   fi
else
   MSG="ERROR: Values are not valid digits to calculate usage: heap_used=${heap_used}, heap_committed=${heap_committed}, heap_max=${heap_max}"
   EXIT_CODE=$NAGIOS_CRIT
fi

echo -e $MSG
exit $EXIT_CODE
