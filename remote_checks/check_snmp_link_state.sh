#!/bin/bash

# Karol Siedlaczek 2023

IF_NAME_OID="1.3.6.1.2.1.31.1.1.1.1"          # IF-MIB::ifName.X
IF_INDEX_OID=".1.3.6.1.2.1.2.2.1.1"           # IF-MIB::ifIndex.X
IF_OPER_STATUS_OID=".1.3.6.1.2.1.2.2.1.8"     # IF-MIB::ifOperStatus.X
IF_HIGH_SPEED_OID=".1.3.6.1.2.1.31.1.1.1.15"  # IF-MIB::ifHighSpeed.X
IF_LAST_CHANGE_OID=".1.3.6.1.2.1.2.2.1.9"     # IF-MIB::ifLastChange.X
SYS_UP_TIME_OID=".1.3.6.1.2.1.1.3.0"          # MIB: system.SysUpTime.0

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
SNMP_PORT="161"
SNMP_COMMUNITY="public"
AUTH_PROTOCOL="SHA"
PRIV_PROTOCOL="AES"
NAGIOS_OUTPUT=false
MINIMAL_OUTPUT=false
LINE_SEPARATOR="\n"
MAX_OIDS=128
OIDS=("${IF_NAME_OID}" "${IF_OPER_STATUS_OID}" "${IF_HIGH_SPEED_OID}" "${IF_LAST_CHANGE_OID}")

function timeticks_to_timestamp {
  timeticks=$1
  timestamp=$(echo "$timeticks" | awk '{ timestamp=$1/8640000*24*60*60; printf "%.2f", timestamp }')
  echo "$(date --date="$timestamp seconds ago" +%s)"
}

function HELP {
  echo "DESCRIPTION"
  echo -e "Check state and speed of interfaces on remote host via SNMP v3 or v2"\\n
  echo "USAGE"
  echo "  -H=HOSTNAME                Remote host address"
  echo "  -l=SNMP_USER               SNMP v3 authentication user"
  echo "  -X=SNMP_PASSWD             SNMP v3 authentication passphrase and encryption passphrase"
  echo "  -p=SNMP_PORT               SNMP port, default is $SNMP_PORT"
  echo "  -C=SNMP_COMMUNITY          SNMP v2 community, default is $SNMP_COMMUNITY"
  echo "  -a=AUTH_PROTOCOL           Authentication protocol, default is (MD5|SHA, default: $AUTH_PROTOCOL)"
  echo "  -x=PRIV_PROTOCOL           Priv protocol, default is (AES|DES, default: $PRIV_PROTOCOL)"
  echo "  -e=EXCLUDE_PATTERN         Regex pattern to exclude interfaces by name, state of these links will not be checked"
  echo "  -m=MATCH_PATTERN           Regex pattern to match interfaces by name, only state of these links will be checked"
  echo "  -t=THRESHOLD_MINUTES       Max duration in minutes that interface may be in critical state (false-positive prevention when link is flapping), "
  echo "                             e.g. if interface is DOWN since <THRESHOLD_MINUTES critical will not be raised"
  echo "  -w=WARN_SPEED_THRESHOLD    Interface speed below this threshold will raise warning (Mb/s)"
  echo "  -c=CRIT_SPEED_THRESHOLD    Interface speed below this threshold will raise critical (Mb/s)"
  echo "  -M=MAX_OIDS                Define allowed count of OIDs in single snmpwalk or snmpget"
  echo "  -s                         Minimal output"
  echo "  -v                         Verbose output"
  echo "  -n                         Enable nagios escape output with </br> at the end of line"
  echo "  -h                         Show this help message and exit"
  exit $NAGIOS_UNKNOWN
}

while getopts H:l:X:C:p:a:x:e:m:t:w:c:M:nsvh flag
do
  case "${flag}" in
    H) HOST_ADDRESS=${OPTARG};;
    l) SNMP_USER=${OPTARG};;
    X) SNMP_PASSWORD=${OPTARG};;
    C) SNMP_COMMUNITY=${OPTARG};;
    p) SNMP_PORT=${OPTARG};;
    a) AUTH_PROTOCOL=${OPTARG};;
    x) PRIV_PROTOCOL=${OPTARG};;
    e) EXCLUDE_PATTERN=${OPTARG};;
    m) MATCH_PATTERN=${OPTARG};;
    t) THRESHOLD_MIN=${OPTARG};;
    w) WARN=${OPTARG};;
    c) CRIT=${OPTARG};;
    M) MAX_OIDS=${OPTARG};;
    s) MINIMAL_OUTPUT=true;;
    v) VERBOSE=true;;
    n) NAGIOS_OUTPUT=true;;
    *) HELP;;
  esac
done

if [[ -z "$HOST_ADDRESS" ]]
then
  echo -e "ERROR: Usage $0 -H <HOST_ADDRESS>\n"
  HELP
elif [[ -n "$EXCLUDE_PATTERN" && -n "$MATCH_PATTERN" ]]
then
  echo -e "ERROR: Flags -m and -e are mutually exclusive\n"
  HELP
elif [[ $CRIT -gt $WARN ]]
then
  echo -e "ERROR: Critical ($CRIT) threshold to measure minimum link speed cannot be greater than warning ($WARN) threshold\n"
  HELP
fi

if [[ -n "$SNMP_USER" ]]
then
  snmp_base_args="-O qtv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT}"
else
  snmp_base_args="-O qtv -v 2c -c ${SNMP_COMMUNITY} ${HOST_ADDRESS}:${SNMP_PORT}"
fi

link_indexes=($(snmpwalk ${snmp_base_args} ${IF_INDEX_OID}))
output_exit_code=$?

if [ $output_exit_code -gt 0 ]
then
  echo "ERROR: No response from remote host $HOST_ADDRESS, exit code is $output_exit_code"
  exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_OUTPUT = true ]]; then LINE_SEPARATOR="</br>"; fi

snmp_cmds=("snmpget ${snmp_base_args} ${SYS_UP_TIME_OID} ")

oid_count=1

for index in "${link_indexes[@]}" # prepare snmp command/s to prevent build snmpget bigger than $MAX_OIDS
do
  for oid in "${OIDS[@]}"
  do
    snmp_cmds[${#snmp_cmds[@]} - 1]+="$oid.$index "
    oid_count=$((oid_count + 1))
    if [ $(( oid_count % MAX_OIDS)) == 0 ]
    then
      snmp_cmds+=("snmpget ${snmp_base_args} ")
    fi
  done
done

for cmd in "${snmp_cmds[@]}"
do
  if [ -z "$snmp_output" ]
  then
    mapfile -t snmp_output <<< $($cmd)
  else
    mapfile -t -O "${#snmp_output[@]}" snmp_output <<< $($cmd)
  fi
done

sys_uptime_timeticks=${snmp_output[0]}
unset snmp_output[0]
snmp_output=("${snmp_output[@]}")
curr_timestamp=$(date +%s)
links_not_ok=0
links_ok=0

for index in "${link_indexes[@]}" # snmp_output structure: [(if_name_1, if_state_1, if_speed_1, if_last_change_1) ... (if_name_n, if_state_n, if_speed_n, if_last_change_n))
do
  link_name=${snmp_output[0]}
  if [[ $EXCLUDE_PATTERN && $link_name =~ $EXCLUDE_PATTERN ]]
  then
    if [[ -n $VERBOSE ]]; then echo "Link $link_name excluded${LINE_SEPARATOR}"; fi
  elif [[ -z $MATCH_PATTERN || $link_name =~ $MATCH_PATTERN ]]
  then
    link_state=${snmp_output[1]}
    link_speed=${snmp_output[2]}
    link_info="Link ${link_name} is ${link_state}"

    if [[ -n $WARN || -n $CRIT ]]  # add speed to output if thresholds to measure are given
    then
      link_info="${link_info} [${link_speed} Mb/s]"
    fi

    if [[ "$link_state" != *"up"* ]]
    then
      last_change_seconds_ago=$(timeticks_to_timestamp $((sys_uptime_timeticks - snmp_output[3]))) # to calculate since when link is down
      last_change_timestamp=$(date --date="@$last_change_seconds_ago" +%s)
      last_change_date=$(date --date="@$last_change_seconds_ago" +"%Y-%m-%d %H:%M:%S")
      since_last_change=$((curr_timestamp - last_change_timestamp)) # in seconds

      if [[ -n $THRESHOLD_MIN && $((since_last_change / 60)) -ge $THRESHOLD_MIN ]]
      then
        if [[ $EXIT_CODE != $NAGIOS_CRIT ]]; then EXIT_CODE=$NAGIOS_OK; fi
        if [[ $MINIMAL_OUTPUT = false ]]; then msg="${msg}OK: ${link_info} since $last_change_date (>$THRESHOLD_MIN mins in this state)${LINE_SEPARATOR}"; fi
        links_ok=$((links_ok + 1))
      else
        EXIT_CODE=$NAGIOS_CRIT
        msg="${msg}CRITICAL: ${link_info} since $last_change_date${LINE_SEPARATOR}"
        links_not_ok=$((links_not_ok + 1))
      fi
    elif [[ -n $CRIT && $link_speed -lt $CRIT ]]
    then
      EXIT_CODE=$NAGIOS_CRIT
      msg="${msg}CRITICAL: ${link_info} (speed < ${CRIT} Mb/s)${LINE_SEPARATOR}"
      links_not_ok=$((links_not_ok + 1))
    elif [[ -n $WARN && $link_speed -lt $WARN ]]
    then
      if [[ $EXIT_CODE != $NAGIOS_CRIT ]]; then EXIT_CODE=$NAGIOS_WARN; fi
      msg="${msg}WARNING: ${link_info} (speed < ${WARN} Mb/s)${LINE_SEPARATOR}"
      links_not_ok=$((links_not_ok + 1))
    else
      if [[ $EXIT_CODE != $NAGIOS_CRIT && $EXIT_CODE != $NAGIOS_WARN ]]; then EXIT_CODE=$NAGIOS_OK; fi
      if [[ $MINIMAL_OUTPUT = false ]]; then msg="${msg}OK: $link_info${LINE_SEPARATOR}"; fi
      links_ok=$((links_ok + 1))
    fi
  else
    if [[ -n $VERBOSE ]]; then echo "link $link_name not matched${LINE_SEPARATOR}"; fi
  fi

  for i in "${!OIDS[@]}"
  do
    unset snmp_output[$i]
  done
  snmp_output=("${snmp_output[@]}")
done

if [ $links_ok -eq 0 ] && [ $links_not_ok -eq 0 ]
then
  echo "ERROR: All links has been excluded from output by /$EXCLUDE_PATTERN/ exclude pattern or not matched by /$MATCH_PATTERN/ match pattern"
  exit $NAGIOS_UNKNOWN
fi

if [[ $MINIMAL_OUTPUT = true ]]
then
  if [[ $links_not_ok -eq 0 ]]
  then
    msg="OK: All links ok${LINE_SEPARATOR}${msg}"
  else
    msg="${links_not_ok}/${#link_indexes[@]} links not ok${LINE_SEPARATOR}${msg}"
  fi
fi

if [[ $NAGIOS_OUTPUT = true ]]; then echo -e ${msg%?????}; else echo -e ${msg%??}; fi
exit $EXIT_CODE
