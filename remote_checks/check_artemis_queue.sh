#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
STATUS_CODE=$NAGIOS_OK

ARTEMIS_USER=$1
ARTEMIS_PASS=$2
ARTEMIS_HOST=$3
ARTEMIS_PORT=$4
WARN=$5
CRIT=$6
QUEUE=$7

if [[ -z "$ARTEMIS_USER" || -z "$ARTEMIS_PASS" || -z "$ARTEMIS_HOST" || -z "$ARTEMIS_PORT" || -z "$WARN" || -z "$CRIT" || -z "$QUEUE" ]]
then
   echo "ERROR: Usage $0 <ARTEMIS_USER> <ARTEMIS_PASS> <ARTEMIS_HOST> <ARTEMIS_PORT> <WARN> <CRIT> <QUEUE>" >&2
   exit $NAGIOS_UNKNOWN
fi

curl_output=$(curl -s --fail --show-error -u ${ARTEMIS_USER}:${ARTEMIS_PASS} ${ARTEMIS_HOST}:${ARTEMIS_PORT}/console/jolokia/read/org.apache.activemq.artemis:address=\"${QUEUE}\",broker="*",component=addresses,queue=\"${QUEUE}\",routing-type=\"anycast\",subcomponent=queues 2>&1)

curl_exit_code=$?

if [ $curl_exit_code -gt 0 ]; then
   echo "ERROR: ${curl_output}"
   exit $NAGIOS_CRIT
fi

queue_names=($(jq -c '.value[].Address' <<< $curl_output))
message_counts=($(jq -c '.value[].MessageCount' <<< $curl_output))

for index in "${!queue_names[@]}"; do
    queue_name=${queue_names[$index]}
    message_count=${message_counts[$index]}
    queue_info="Queue ${queue_name} has ${message_count} messages"

    if [[ $CRIT -lt $message_count ]]; then
        STATUS_CODE=$NAGIOS_CRIT
        MSG="${MSG}CRITICAL: $queue_info (>$CRIT)\n"
    elif  [[ $WARN -lt $message_count ]]; then
        if [[ $STATUS_CODE -lt $NAGIOS_WARN ]]; then STATUS_CODE=$NAGIOS_WARN; fi
        MSG="${MSG}WARNING: $queue_info (>$WARN)\n"
    fi
done

if [[ $STATUS_CODE -gt $NAGIOS_OK ]]; then
    echo -e ${MSG%??}
else
    echo "OK: All queues ok"
fi

exit $STATUS_CODE
