#!/bin/bash

# Karol S. 2023

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
STATUS_CODE=$NAGIOS_OK
WARN="80,80"
CRIT="90,90"
SNMP_PORT="161"
AUTH_PROTOCOL="SHA"
PRIV_PROTOCOL="AES"
NAGIOS_OUTPUT=false
LINE_SEPARATOR="\n"

function HELP {
  echo "DESCRIPTION"
  echo -e "Check available memory and SWAP usage on remote host via SNMP v3 extend script meminfo"\\n
  echo "USAGE"
  echo "  -H=HOSTNAME           Remote host address"
  echo "  -l=SNMP_USER          SNMP v3 authentication user"
  echo "  -X=SNMP_PASSWD        SNMP v3 authentication passphrase and encryption passphrase"
  echo "  -p=SNMP_PORT          SNMP port, default is $SNMP_PORT"
  echo "  -a=AUTH_PROTOCOL      Authentication protocol, default is (MD5|SHA, default: $AUTH_PROTOCOL)"
  echo "  -x=PRIV_PROTOCOL      Priv protocol, default is (AES|DES, default: $PRIV_PROTOCOL)"
  echo "  -w=INT | INT,INT      Warning level for memory in percent, arg <INTEGER> only for available mem, <INTEGER>,<INTEGER> also for SWAP, default is $WARN"
  echo "  -c=INT | INT,INT      Critical level for memory in percent, arg <INTEGER> only for available mem, <INTEGER>,<INTEGER> also for SWAP, default is $CRIT"
  echo "  -n                    No argument, enable nagios escape output with </br> at the end of line"
  echo "  -h                    Show this help message and exit"
  exit 1
}

while getopts H:l:X:p:a:x:w:c:hn flag
do
  case "${flag}" in
    H) HOST_ADDRESS=${OPTARG};;
    l) SNMP_USER=${OPTARG};;
    X) SNMP_PASSWORD=${OPTARG};;
    p) SNMP_PORT=${OPTARG};;
    a) AUTH_PROTOCOL=${OPTARG};;
    x) PRIV_PROTOCOL=${OPTARG};;
    w) WARN=${OPTARG};;
    c) CRIT=${OPTARG};;
    n) NAGIOS_OUTPUT=true;;
    *) HELP;;
  esac
done

SNMPGET_OUTPUT=$(snmpget -O qUv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT} NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"meminfo\")
SNMPGET_EXIT_CODE=$?

if [ $SNMPGET_EXIT_CODE -gt 0 ]
then
  echo "ERROR: no response from remote host $HOST_ADDRESS, return exit code is $SNMPGET_EXIT_CODE"
  exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_OUTPUT = true ]]; then LINE_SEPARATOR="</br>"; fi

MEM_WARN=$(echo $WARN | awk '{split($0,x,","); print x[1]}')
MEM_CRIT=$(echo $CRIT | awk '{split($0,x,","); print x[1]}')
SWAP_WARN=$(echo $WARN | awk '{split($0,x,","); print x[2]}')
SWAP_CRIT=$(echo $CRIT | awk '{split($0,x,","); print x[2]}')

MEM_FREE_AND_SWAP_FREE=$(echo "$SNMPGET_OUTPUT" | awk '{split($0,x,": "); print x[2]}')
MEM_FREE=$(echo "$MEM_FREE_AND_SWAP_FREE" | awk '{split($0, x, "/"); print x[1]}')
SWAP_FREE=$(echo "$MEM_FREE_AND_SWAP_FREE" | awk '{split($0, x, "/"); print x[2]}')

if [[ $MEM_FREE == +([[:digit:]]) ]]
then
  MEM_USAGE=$((100 - $MEM_FREE))
  if [[ $MEM_CRIT -lt $MEM_USAGE ]]
  then
    MSG="CRITICAL: Memory usage ${MEM_USAGE}% > ${MEM_CRIT}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_CRITICAL
  elif [[ $MEM_WARN -lt $MEM_USAGE ]]
  then
    MSG="WARNING: Memory usage ${MEM_USAGE}% > ${MEM_WARN}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_WARN
  else
    MSG="OK: Memory usage ${MEM_USAGE}%${LINE_SEPARATOR}"
  fi
else
  OUTPUT=$(snmpwalk -O qv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT} NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"meminfo\")
  echo "CRITICAL: $OUTPUT"
  exit $NAGIOS_CRIT
fi

if [[ $SWAP_FREE -ne 0 ]]
then
  SWAP_USAGE=$((100 - $SWAP_FREE))
  if [ -z "$SWAP_CRIT" ]; then SWAP_CRIT=$MEM_CRIT; fi
  if [ -z "$SWAP_WARN" ]; then SWAP_WARN=$MEM_WARN; fi
  if [[ $SWAP_CRIT -lt $SWAP_USAGE ]]
  then
    MSG="${MSG}CRITICAL: SWAP usage ${SWAP_USAGE}% > ${SWAP_CRIT}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_CRITICAL
  elif [[ $SWAP_WARN -lt $SWAP_USAGE ]]
  then
    MSG="${MSG}WARNING: SWAP usage ${SWAP_USAGE}% > ${SWAP_WARN}%${LINE_SEPARATOR}"
    if [[ $STATUS_CODE -lt $NAGIOS_WARN ]]; then STATUS_CODE=$NAGIOS_WARN; fi # do not change higher status code
  else
    MSG="${MSG}OK: SWAP usage ${SWAP_USAGE}%${LINE_SEPARATOR}"
  fi
fi

if [[ $NAGIOS_OUTPUT = true ]]; then echo -e ${MSG%?????}; else echo -e ${MSG%??}; fi
exit $STATUS_CODE