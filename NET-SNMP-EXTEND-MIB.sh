#!/bin/bash

SNMP_HOST=$1
SNMP_PORT=$2
SNMP_USER=$3
SNMP_PASS=$4
EXTEND_NAME=$5

if [[ -z "$SNMP_HOST" || -z "$SNMP_PORT" || -z "$SNMP_USER" || -z "$SNMP_PASS" || -z "$EXTEND_NAME" ]]
then
   echo -e "Syntax error\nUsage: $0 <host> <port> <user> <pass> <extend>"
   exit 0
fi

# For output
output=$(/usr/bin/snmpget -t 10 -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"$EXTEND_NAME\")

# For exit code
result=$(/usr/bin/snmpget -t 10 -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendResult.\"$EXTEND_NAME\")

echo $output
echo $result
