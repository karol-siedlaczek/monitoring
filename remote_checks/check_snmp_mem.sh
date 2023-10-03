#!/bin/bash

# Karol Siedlaczek 2023

SYS_AVAIL_OID=".1.3.6.1.4.1.2021.4.27.0" # MIB: memSysAvail.0
TOTAL_REAL_OID=".1.3.6.1.4.1.2021.4.5.0" # MIB: memTotalReal.0
AVAIL_SWAP_OID=".1.3.6.1.4.1.2021.4.4.0" # MIB: memAvailSwap.0
TOTAL_SWAP_OID=".1.3.6.1.4.1.2021.4.3.0" # MIB: memTotalSwap.0

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
  echo -e "Check available memory and SWAP usage on remote host via SNMP v3, requires $SYS_AVAIL_OID and $TOTAL_REAL_OID OIDs on remote machine, if total SWAP is 0 on remote host it will not be included in output"\\n
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
  exit $NAGIOS_UNKNOWN
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

if [[ -z "$HOST_ADDRESS" || -z "$SNMP_USER" || -z "$SNMP_PASSWORD" ]]
then
  echo -e "ERROR: usage $0 -H <HOST_ADDRESS> -l <SNMP_USER> -X <SNMP_PASSWORD>\n"
  HELP
fi

if [[ $NAGIOS_OUTPUT = true ]]; then LINE_SEPARATOR="</br>"; fi

SNMPGET_RESULT=($(snmpget -O qUv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT} ${SYS_AVAIL_OID} ${TOTAL_REAL_OID} ${AVAIL_SWAP_OID} ${TOTAL_SWAP_OID}))
SNMPGET_EXIT_CODE=$?

if [ $SNMPGET_EXIT_CODE -gt 0 ]
then
  echo "ERROR: no response from remote host $HOST_ADDRESS, exit code is $SNMPGET_EXIT_CODE"
  exit $NAGIOS_UNKNOWN
fi

MEM_AVAIL=${SNMPGET_RESULT[0]}
MEM_TOTAL=${SNMPGET_RESULT[1]}
MEM_WARN=$(echo $WARN | awk '{split($0,x,","); print x[1]}')
MEM_CRIT=$(echo $CRIT | awk '{split($0,x,","); print x[1]}')
SWAP_AVAIL=${SNMPGET_RESULT[2]}
SWAP_TOTAL=${SNMPGET_RESULT[3]}
SWAP_WARN=$(echo $WARN | awk '{split($0,x,","); print x[2]}')
SWAP_CRIT=$(echo $CRIT | awk '{split($0,x,","); print x[2]}')

if [[ $MEM_AVAIL == +([[:digit:]]) ]]
then
  MEM_USAGE=$(($MEM_TOTAL - $MEM_AVAIL))
  MEM_USAGE_PERCENT=$(($MEM_USAGE*100 / $MEM_TOTAL))
  if [[ $MEM_CRIT -lt $MEM_USAGE_PERCENT ]]
  then
    MSG="CRITICAL: Memory usage ${MEM_USAGE_PERCENT}% > ${MEM_CRIT}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_CRITICAL
  elif [[ $MEM_WARN -lt $MEM_USAGE_PERCENT ]]
  then
    MSG="WARNING: Memory usage ${MEM_USAGE_PERCENT}% > ${MEM_WARN}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_WARN
  else
    MSG="OK: Memory usage ${MEM_USAGE_PERCENT}%${LINE_SEPARATOR}"
  fi
else
  OUTPUT=$(snmpwalk -O qv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT} ${SYS_AVAIL_OID} ${TOTAL_REAL_OID} ${AVAIL_SWAP_OID} ${TOTAL_SWAP_OID})
  echo "CRITICAL: $OUTPUT; ${SYS_AVAIL_OID}, ${TOTAL_REAL_OID} OIDs are minimal requirement on remote host $HOST_ADDRESS"
  exit $NAGIOS_CRIT
fi

if [[ $SWAP_TOTAL -ne 0 ]]
then
  if [ -z "$SWAP_CRIT" ]; then SWAP_CRIT=$MEM_CRIT; fi
  if [ -z "$SWAP_WARN" ]; then SWAP_WARN=$MEM_WARN; fi
  SWAP_USAGE=$(($SWAP_TOTAL-$SWAP_AVAIL))
  SWAP_USAGE_PERCENT=$(($SWAP_USAGE*100/$SWAP_TOTAL))
  if [[ $SWAP_CRIT -lt $SWAP_USAGE_PERCENT ]]
  then
    MSG="${MSG}CRITICAL: SWAP usage ${SWAP_USAGE_PERCENT}% > ${SWAP_CRIT}%${LINE_SEPARATOR}"
    STATUS_CODE=$NAGIOS_CRITICAL
  elif [[ $SWAP_WARN -lt $SWAP_USAGE_PERCENT ]]
  then
    MSG="${MSG}WARNING: SWAP usage ${SWAP_USAGE_PERCENT}% > ${SWAP_WARN}%${LINE_SEPARATOR}"
    if [[ $STATUS_CODE -lt $NAGIOS_WARN ]]; then STATUS_CODE=$NAGIOS_WARN; fi # do not change higher status code
  else
    MSG="${MSG}OK: SWAP usage ${SWAP_USAGE_PERCENT}%${LINE_SEPARATOR}"
  fi
fi

if [[ $NAGIOS_OUTPUT = true ]]; then echo -e ${MSG%?????}; else echo -e ${MSG%??}; fi
exit $STATUS_CODE