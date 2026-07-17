#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

HOST_ADDRESS=$1
SNMP_USER=$2
SNMP_PASSWORD=$3

if [[ -z "$HOST_ADDRESS" || -z "$SNMP_USER" || -z "$SNMP_PASSWORD" ]]
then
   echo "ERROR: Usage $0 <HOST_ADDRESS> <SNMP_USER> <SNMP_PASS>" >&2
   exit $NAGIOS_UNKNOWN
fi

SNMP_COMMON="snmpwalk -v 3 -u $SNMP_USER -A $SNMP_PASSWORD -X $SNMP_PASSWORD -a SHA -x AES -l authPriv -Ovq $HOST_ADDRESS"
snmp_output=$($SNMP_COMMON NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"opensearch_cluster_health\")
output_exit_code=$?

if [ $output_exit_code -gt 0 ]
then
  echo "ERROR: No response from remote host $HOST_ADDRESS, exit code is $output_exit_code"
  exit $NAGIOS_UNKNOWN
elif ! jq <<< "$snmp_output" > /dev/null 2>&1
then
  echo "ERROR: $snmp_output"
  exit $NAGIOS_UNKNOWN
fi

health_status=$(jq '.status' <<< "$snmp_output")

if [[ "$health_status" == *"green"* ]]; then
    EXIT_CODE=$NAGIOS_OK
elif [[ "$health_status" == *"yellow"* ]]; then
    EXIT_CODE=$NAGIOS_WARN
else
    EXIT_CODE=$NAGIOS_CRIT
fi

if [[ -z $health_status ]]
then
  echo "CRITICAL: Cluster status is unknown"
  EXIT_CODE=$NAGIOS_UNKNOWN
else
  echo "Cluster status is $health_status"
fi

exit $EXIT_CODE
