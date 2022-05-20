#!/bin/bash

SNMPGET="/usr/bin/snmpget -t 10"
NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRITICAL=2
NAGIOS_UNKNOWN=3

SNMP_HOST=$1
SNMP_PORT=$2
SNMP_USER=$3
SNMP_PASS=$4
EXTEND_NAME=$5

if [[ -z "$SNMP_HOST" || -z "$SNMP_PORT" || -z "$SNMP_USER" || -z "$SNMP_PASS" || -z "$EXTEND_NAME" ]]
then
   echo -e "Syntax error\nUsage: $0 <host> <port> <user> <pass> <extend>"
   exit $NAGIOS_UNKNOWN
fi

cmd_result=$($SNMPGET -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendResult.\"$EXTEND_NAME\")
cmd_output=""
if [ -n "$cmd_result" ];
then
    cmd_output=$($SNMPGET -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"$EXTEND_NAME\")
fi

if [ -z "$cmd_output"  ]
then
    echo "Communication error with remote host"
    exit $NAGIOS_UNKNOWN
fi

echo $cmd_output
exit $cmd_result
