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

if [[ -z "$SNMP_HOST" || -z "$SNMP_PORT" || -z "$SNMP_USER" || -z "$SNMP_PASS" || -z "$EXTEND_NAME" || -z "$MAIL_TITLE" || -z "$MAIL_RECIPIENT" ]]
then
   echo -e "Syntax error\nUsage: $0 <host> <port> <user> <pass> <extend> <mail_title> <mail_recipient>"
   exit $NAGIOS_UNKNOWN
fi

tmp_file=".${0##*/}-${EXTEND_NAME}-${SNMP_HOST}"
tmp_file=${tmp_file//.sh/.tmp}

cmd_result=$($SNMPGET -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendResult.\"$EXTEND_NAME\")
cmd_output=""
if [ -n "$cmd_result" ]
then
    cmd_output=$($SNMPGET -OQv -l authPriv -u $SNMP_USER -A $SNMP_PASS -X $SNMP_PASS $SNMP_HOST:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"$EXTEND_NAME\")
fi

if [ -z "$cmd_output"  ]
then
    echo "Communication error with remote host"
    exit $NAGIOS_UNKNOWN
fi

if [ ! -f "/tmp/$tmp_file" ]
then
    touch "/tmp/$tmp_file"
fi

if [ "$cmd_result" == "$NAGIOS_CRITICAL" ]
then
    state=$(cat "/tmp/$tmp_file")
    if [ "$state" != "$NAGIOS_CRITICAL" ]
    then
        hostname=$(snmpwalk -O qv -c public -v 2c $SNMP_HOST .1.3.6.1.2.1.1.5.0 | tr -d '"')
        mail_output=${cmd_output//<br\/>/\\n}
        echo -e ${mail_output} | mail -s "$hostname $MAIL_TITLE" $MAIL_RECIPIENT
        echo $NAGIOS_CRITICAL > "/tmp/$tmp_file"
    fi
else
    echo $cmd_result > "/tmp/$tmp_file"
fi

echo $cmd_output
exit $cmd_result
