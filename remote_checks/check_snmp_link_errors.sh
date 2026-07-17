#!/bin/bash

# Karol Siedlaczek 2023

# Define OIDs
IF_NAME_OID="1.3.6.1.2.1.31.1.1.1.1"
IF_INDEX_OID="1.3.6.1.2.1.2.2.1.1"
IF_IN_ERRORS_OID="1.3.6.1.2.1.2.2.1.14"
IF_OUT_ERRORS_OID="1.3.6.1.2.1.2.2.1.20"

# Nagios status codes
NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

SNMP_PORT="161"
SNMP_COMMUNITY="public"
AUTH_PROTOCOL="SHA"
PRIV_PROTOCOL="AES"
LINE_SEPARATOR="\n"
MAX_OIDS=128

# Error rate thresholds
ERROR_RATE_CRIT=10
ERROR_RATE_WARN=5

function HELP {
  echo "DESCRIPTION"
  echo "Check interface error rates on remote host via SNMP v3 or v2"
  echo "USAGE: $0 -H <HOST> [-l <USER>] [-X <PASS>] [-C <COMM>] [-p <PORT>] [-a <AUTH>] [-x <PRIV>] [-E <CRIT>] [-W <WARN>] [-M <MAX_OIDS>] [-h]"
  exit $NAGIOS_UNKNOWN
}

while getopts H:l:X:C:p:a:x:E:W:M:h flag
do
  case "${flag}" in
    H) HOST_ADDRESS=${OPTARG};;
    l) SNMP_USER=${OPTARG};;
    X) SNMP_PASSWORD=${OPTARG};;
    C) SNMP_COMMUNITY=${OPTARG};;
    p) SNMP_PORT=${OPTARG};;
    a) AUTH_PROTOCOL=${OPTARG};;
    x) PRIV_PROTOCOL=${OPTARG};;
    E) ERROR_RATE_CRIT=${OPTARG};;
    W) ERROR_RATE_WARN=${OPTARG};;
    M) MAX_OIDS=${OPTARG};;
    h) HELP;;
    *) HELP;;
  esac
done

if [[ -z "$HOST_ADDRESS" ]]; then
  echo "ERROR: Missing host address."
  HELP
fi

CACHE_FILE="/tmp/snmp_interface_errors_${HOST_ADDRESS}.cache"

if [[ -n "$SNMP_USER" ]]; then
  snmp_base_args="-O qtv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT}"
else
  snmp_base_args="-O qtv -v 2c -c ${SNMP_COMMUNITY} ${HOST_ADDRESS}:${SNMP_PORT}"
fi

link_indexes=($(snmpwalk ${snmp_base_args} ${IF_INDEX_OID} | awk '{print $NF}'))
if [ $? -gt 0 ] || [ ${#link_indexes[@]} -eq 0 ]; then
  echo "ERROR: No response from remote host $HOST_ADDRESS"
  exit $NAGIOS_UNKNOWN
fi

# Define OIDs to fetch
OIDS=("${IF_NAME_OID}" "${IF_IN_ERRORS_OID}" "${IF_OUT_ERRORS_OID}")

# Build and execute SNMP queries
snmp_cmds=()
snmp_cmd="snmpget ${snmp_base_args}"
oid_count=0

for index in "${link_indexes[@]}"; do
  for oid in "${OIDS[@]}"; do
    snmp_cmd+=" ${oid}.${index}"
    ((oid_count++))
    if ((oid_count >= MAX_OIDS)); then
      snmp_cmds+=("$snmp_cmd")
      snmp_cmd="snmpget ${snmp_base_args}"
      oid_count=0
    fi
  done
done

if [[ -n "$snmp_cmd" && "$snmp_cmd" != "snmpget ${snmp_base_args}" ]]; then
  snmp_cmds+=("$snmp_cmd")
fi

snmp_output=()
for cmd in "${snmp_cmds[@]}"
do
  mapfile -t -O "${#snmp_output[@]}" snmp_output <<< $($cmd)
done

# Validate output size
expected_output_size=$(( ${#link_indexes[@]} * ${#OIDS[@]} ))
if [[ ${#snmp_output[@]} -ne $expected_output_size ]]; then
  echo "ERROR: Unexpected SNMP response size."
  exit $NAGIOS_UNKNOWN
fi

first_run=false
if [[ ! -f "$CACHE_FILE" ]]; then
  first_run=true
fi
# Load previous error counts
declare -A prev_in_errors
declare -A prev_out_errors


if ! $first_run; then
  while IFS= read -r line; do
    read -r host iface prev_in prev_out <<< "$line"
    if [[ "$host" == "$HOST_ADDRESS" ]]; then
      prev_in_errors["$iface"]=$prev_in
      prev_out_errors["$iface"]=$prev_out
    fi
  done < "$CACHE_FILE"
fi


critical_interfaces=""
warning_interfaces=""
ok_interfaces=""
new_cache=""

index=0
for link_index in "${link_indexes[@]}"; do
  link_name="${snmp_output[$index]}"
  in_errors="${snmp_output[$((index+1))]}"
  out_errors="${snmp_output[$((index+2))]}"

  if [[ -z "$link_name" || -z "$in_errors" || -z "$out_errors" ]]; then
    echo "ERROR: Missing SNMP data for index $link_index."
    exit $NAGIOS_UNKNOWN
  fi

  # Get previous values
  prev_in=${prev_in_errors[$link_name]:-0}
  prev_out=${prev_out_errors[$link_name]:-0}

  # Calculate error rate
  if $first_run; then
    in_rate=0
    out_rate=0
  else
    in_rate=$(( in_errors - prev_in ))
    out_rate=$(( out_errors - prev_out ))
  fi

  # Save new values to cache
  new_cache+="$HOST_ADDRESS ${link_name} ${in_errors} ${out_errors}\n"

  # Determine interface status
  if (( in_rate > ERROR_RATE_CRIT || out_rate > ERROR_RATE_CRIT )); then
    critical_interfaces+="CRITICAL: ${link_name} (IN: $in_rate, OUT: $out_rate)${LINE_SEPARATOR}"
  elif (( in_rate > ERROR_RATE_WARN || out_rate > ERROR_RATE_WARN )); then
    warning_interfaces+="WARNING: ${link_name} (IN: $in_rate, OUT: $out_rate)${LINE_SEPARATOR}"
  else
    ok_interfaces+="OK: ${link_name} (IN: $in_rate, OUT: $out_rate)${LINE_SEPARATOR}"
  fi

  index=$((index + 3))
done

# Save new data to cache
if [[ -f "$CACHE_FILE" ]]; then
  grep -v "^$HOST_ADDRESS " "$CACHE_FILE" > "${CACHE_FILE}.tmp" || true
else
  touch "${CACHE_FILE}.tmp"
  chmod 666 "${CACHE_FILE}.tmp"
fi
# Append new data for this host
echo -e "$new_cache" >> "${CACHE_FILE}.tmp"

# Replace the old cache file with the updated one
mv "${CACHE_FILE}.tmp" "$CACHE_FILE"


# Determine exit code
if $first_run; then
  echo -e "First run detected. Initializing cache. All interfaces OK."
  echo -e "$ok_interfaces"
  exit $NAGIOS_OK
elif [ -n "$critical_interfaces" ]; then
  echo -e "$critical_interfaces"
  exit $NAGIOS_CRIT
elif [ -n "$warning_interfaces" ]; then
  echo -e "$warning_interfaces"
  exit $NAGIOS_WARN
else
  echo -e "$ok_interfaces"
  exit $NAGIOS_OK
fi
