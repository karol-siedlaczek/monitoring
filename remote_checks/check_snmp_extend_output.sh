#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
SNMP_PORT="161"
SNMP_COMMUNITY="public"
AUTH_PROTOCOL="SHA"
PRIV_PROTOCOL="AES"

function HELP {
  echo "DESCRIPTION"
  echo -e "Check output of extend by regex via SNMP v3"\\n
  echo "USAGE"
  echo "  -H=HOSTNAME                Remote host address"
  echo "  -l=SNMP_USER               SNMP v3 authentication user"
  echo "  -X=SNMP_PASSWD             SNMP v3 authentication passphrase and encryption passphrase"
  echo "  -p=SNMP_PORT               SNMP port, default is $SNMP_PORT"
  echo "  -e=SNMP_EXTEND             SNMP extend name"
  echo "  -a=AUTH_PROTOCOL           Authentication protocol, default is (MD5|SHA, default: $AUTH_PROTOCOL)"
  echo "  -x=PRIV_PROTOCOL           Priv protocol, default is (AES|DES, default: $PRIV_PROTOCOL)"
  echo "  -o=OUTPUT_PATTERN          Regex pattern to match output by extend"
  echo "  -h                         Show this help message and exit"
  exit $NAGIOS_UNKNOWN
}

while getopts H:l:X:p:e:a:x:o: flag
do
  case "${flag}" in
    H) HOST_ADDRESS=${OPTARG};;
    l) SNMP_USER=${OPTARG};;
    X) SNMP_PASSWORD=${OPTARG};;
    p) SNMP_PORT=${OPTARG};;
    e) SNMP_EXTEND=${OPTARG};;
    a) AUTH_PROTOCOL=${OPTARG};;
    x) PRIV_PROTOCOL=${OPTARG};;
    o) OUTPUT_PATTERN=${OPTARG};;
    *) HELP;;
  esac
done

if [[ -z "$HOST_ADDRESS" || -z "$SNMP_USER" || -z "$SNMP_PASSWORD" || -z "$SNMP_EXTEND" || -z "$OUTPUT_PATTERN" ]]
then
   echo "ERROR: Usage $0 <HOST_ADDRESS> <SNMP_USER> <SNMP_PASS> <SNMP_EXTEND> <OUTPUT_PATTERN>" >&2
   HELP
fi

snmp_output=$(snmpwalk -v 3 -u $SNMP_USER -A $SNMP_PASSWORD -X $SNMP_PASSWORD -a $AUTH_PROTOCOL -x $PRIV_PROTOCOL -l authPriv -Ovq $HOST_ADDRESS:$SNMP_PORT NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"$SNMP_EXTEND\" 2>&1)
output_exit_code=$?

if [ $output_exit_code -gt 0 ]
then
  echo "ERROR: $snmp_output"
  exit $NAGIOS_UNKNOWN
fi

if [[ "$snmp_output" =~ "$OUTPUT_PATTERN" ]]; then
  echo "OK: Check $SNMP_EXTEND returned '$snmp_output'"
  EXIT_CODE=$NAGIOS_OK
elif [[ -z $snmp_output ]]; then
  echo "UNKNOWN: Check $SNMP_EXTEND did not return any output from $HOST_ADDRESS"
  EXIT_CODE=$NAGIOS_UNKNOWN
else
  echo "CRITICAL: Check $SNMP_EXTEND returned '$snmp_output'"
  EXIT_CODE=$NAGIOS_CRIT
fi

exit $EXIT_CODE
