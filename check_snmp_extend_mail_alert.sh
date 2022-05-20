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
MAIL_TITLE=$6
MAIL_RECIPIENT=$7

[ -z "$SNMP_HOST" -o -z "$SNMP_PORT" -o -z "$SNMP_USER" -o -z "$SNMP_PASS" -o -z "$EXTEND_NAME" -o -z "$MAIL_TITLE" -o -z "$MAIL_RECIPIENT" ] && {
   echo "Syntax error"
   echo "Usage: $0 <host> <port> <user> <pass> <extend> <mail_title> <mail_recipient>"
   exit $NAGIOS_UNKNOWN
}

TMP_FILE=".${0##*/}-${EXTEND_NAME}-${SNMP_HOST}"
TMP_FILE=${TMP_FILE//.sh/.tmp}

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

if [ ! -f "/tmp/$TMP_FILE" ]
then
    touch "/tmp/$TMP_FILE"
fi

if [ "$cmd_result" == "$NAGIOS_CRITICAL" ]
then
    state=$(cat "/tmp/$TMP_FILE")
    if [ "$state" != "$NAGIOS_CRITICAL" ]
    then
        hostname=$(snmpwalk -O qv -c public -v 2c $SNMP_HOST .1.3.6.1.2.1.1.5.0 | tr -d '"')
        mail_output=${cmd_output//<br\/>/\\n}
        echo -e ${mail_output} | mail -s "$hostname $MAIL_TITLE" $MAIL_RECIPIENT
        echo $NAGIOS_CRITICAL > "/tmp/$TMP_FILE"
    fi
else
    echo $cmd_result > "/tmp/$TMP_FILE"
fi

echo $cmd_output
exit $cmd_result
