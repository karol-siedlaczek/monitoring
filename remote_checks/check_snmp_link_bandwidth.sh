#!/bin/bash

# Karol Siedlaczek 2025

IF_NAME_OID="1.3.6.1.2.1.31.1.1.1.1"          # IF-MIB::ifName.X
IF_INDEX_OID=".1.3.6.1.2.1.2.2.1.1"           # IF-MIB::ifIndex.X
IF_OPER_STATUS_OID=".1.3.6.1.2.1.2.2.1.8"     # IF-MIB::ifOperStatus.X
IF_IN_OCTETS_OID=".1.3.6.1.2.1.31.1.1.1.6"    # IF-MIB::isHCInOctets (Inbound traffic)
IF_OUT_OCTETS_OID=".1.3.6.1.2.1.31.1.1.1.10"  # IF-MIB::isHCOutOctets (Outbound traffic)
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
BINARY_RESULT=false
NAGIOS_ESCAPE=false
SHORT_OUTPUT=false
LINE_SEPARATOR="\n"
MAX_OIDS=128
OIDS=("${IF_NAME_OID}" "${IF_OPER_STATUS_OID}" "${IF_IN_OCTETS_OID}" "${IF_OUT_OCTETS_OID}")

function HELP {
    echo "DESCRIPTION"
    echo -e "Check state of interfaces and link utilization (IN/OUT traffic) on remote host via SNMP v3 or v2"\\n
    echo "USAGE"
    echo "  -H/--host=HOSTNAME                      Remote host address"
    echo "  -l/--user=SNMP_USER                     SNMP v3 authentication user"
    echo "  -X/--password=SNMP_PASSWD               SNMP v3 authentication passphrase and encryption passphrase"
    echo "  -p/--port=SNMP_PORT                     SNMP port, default is $SNMP_PORT"
    echo "  -C/--community=SNMP_COMMUNITY           SNMP v2 community, default is $SNMP_COMMUNITY"
    echo "  -a/--auth=AUTH_PROTOCOL                 Authentication protocol, default is (MD5|SHA, default: $AUTH_PROTOCOL)"
    echo "  -x/--priv=PRIV_PROTOCOL                 Priv protocol, default is (AES|DES, default: $PRIV_PROTOCOL)"
    echo "  -e/--exclude=EXCLUDE_PATTERN            Regex pattern to exclude interfaces by name, state of these links will not be checked"
    echo "  -m/--match=MATCH_PATTERN                Regex pattern to match interfaces by name, only state of these links will be checked"
    echo "  --warn-out=WARN_OUT_TRAFFIC_THRESHOLD   Outbound traffic above this threshold will raise warning (Mb/s)"
    echo "  --crit-out=CRIT_OUT_TRAFFIC_THRESHOLD   Outbound traffic above this threshold will raise critical (Mb/s)"
    echo "  --warn-in=WARN_IN_TRAFFIC_THRESHOLD     Inbound traffic above this threshold will raise warning (Mb/s)"
    echo "  --crit-in=CRIT_IN_TRAFFIC_THRESHOLD     Inbound traffic above this threshold will raise critical (Mb/s)"
    echo "  -M/--max-oids=MAX_OIDS                  Define allowed count of OIDs in single snmpwalk or snmpget"
    echo "  -b/--binary-result                      Enable to calculate values to binary standard (kibi/mebi/gibi etc.), so bytes will be multiplied by 1024"
    echo "  -s/--short                              Short output"
    echo "  -v/--verbose                            Verbose output"
    echo "  -n/--nagios                             Enable nagios escape output with </br> at the end of line"
    echo "  -h/--help                               Show this help message and exit"
    exit $NAGIOS_UNKNOWN
}

function get_traffic_rate {
    local current_octets=$1
    local cached_octets=$2
    local seconds=$3

    if [[ $current_octets -eq 0 && $cached_octets ]]; then
        echo "0 0 $KB_UNIT"
    else
        # Fallback if cache and current data are from the same timestamp
        if [[ $seconds -eq 0 ]]; then
            seconds=1
        fi
        diff=$((current_octets - cached_octets))
        diff_as_bits=$((diff * 8))
        rate_kbps=$((diff_as_bits / $seconds / $UNIT_MULTIPLIER))
        rate_mbps=$((rate_kbps / $UNIT_MULTIPLIER))
        
        if [[ $rate_kbps -ge $UNIT_MULTIPLIER ]]; then
            echo "$rate_mbps $rate_mbps $MB_UNIT"
        else
            echo "$rate_mbps $rate_kbps $KB_UNIT"            
        fi
    fi
}

OPTS=$(getopt -o H:,l:,X:,C:,p:,a:,x:,e:,m:,M:,b,n,s,v,h --long host:,user:,password:,community:,port:,auth:,priv:,exclude:,match:,warn-out:,crit-out:,warn-in:,crit-in:,max-oids:,binary-result,nagios,short,verbose,help -- "$@")
eval set -- "$OPTS"
ARGS=("$@")

while true; do
  case "$1" in
    -H|--host) HOST_ADDRESS=$2; shift 2;;
    -l|--user) SNMP_USER=$2; shift 2;;
    -X|--password) SNMP_PASSWORD=$2; shift 2;;
    -C|--community) SNMP_COMMUNITY=$2; shift 2;;
    -p|--port) SNMP_PORT=$2; shift 2;;
    -a|--auth) AUTH_PROTOCOL=$2; shift 2;;
    -x|--priv) PRIV_PROTOCOL=$2; shift 2;;
    -e|--exclude) EXCLUDE_PATTERN=$2; shift 2;;
    -m|--match) MATCH_PATTERN=$2; shift 2;;
    --warn-out) WARN_OUT_RATE=$2; shift 2;;
    --crit-out) CRIT_OUT_RATE=$2; shift 2;;
    --warn-in) WARN_IN_RATE=$2; shift 2;;
    --crit-in) CRIT_IN_RATE=$2; shift 2;;
    -M|--max-oids) MAX_OIDS=$2; shift 2;;
    -b|--binary-result) BINARY_RESULT=true; shift;;
    -n|--nagios) NAGIOS_ESCAPE=true; shift;;
    -s|--short) SHORT_OUTPUT=true; shift;;
    -v|--verbose) VERBOSE=true; shift;;
    -h|--help) HELP; shift;;
    --) shift; break;;
    *) echo "Invalid option: $1"; exit 1;;
  esac
done

if [[ $BINARY_RESULT = true ]]; then
    UNIT_MULTIPLIER=1024
    KB_UNIT="kib/s"
    MB_UNIT="Mib/s"
else
    UNIT_MULTIPLIER=1000
    KB_UNIT="kb/s"
    MB_UNIT="Mb/s"
fi

if [[ -z "$HOST_ADDRESS" || -z "$WARN_OUT_RATE" || -z "$CRIT_OUT_RATE" || -z "$WARN_IN_RATE" || -z "$CRIT_IN_RATE" ]]; then
    echo -e "ERROR: Required arguments not defined:  -H/--host, --warn-out, --crit-out, --warn-in, --crit-in\n"
    HELP
elif [[ -n "$EXCLUDE_PATTERN" && -n "$MATCH_PATTERN" ]]; then
    echo -e "ERROR: Flags -m/--match and -e/--exclude are mutually exclusive"
    exit $NAGIOS_UNKNOWN
elif [[ $WARN_OUT_RATE -gt $CRIT_OUT_RATE ]]; then
    echo -e "ERROR: Warning threshold ($WARN_OUT_RATE $MB_UNIT) for outbound link traffic cannot be greater than critical threshold ($CRIT_OUT_RATE $MB_UNIT)"
    exit $NAGIOS_UNKNOWN
elif [[ $WARN_IN_RATE -gt $CRIT_IN_RATE ]]; then
    echo -e "ERROR: Warning threshold ($WARN_IN_RATE $MB_UNIT) for inbound link traffic cannot be greater than critical threshold ($CRIT_IN_RATE $MB_UNIT)"
    exit $NAGIOS_UNKNOWN
elif [[ $MAX_OIDS -gt 128 ]]; then
    echo -e "ERROR: Max OIDs variable cannot be greater than 128 (SNMP limitation), current value is $MAX_OIDS"
    exit $NAGIOS_UNKNOWN
fi

if [[ -n "$SNMP_USER" ]]; then
    snmp_base_args="-O qtv -v 3 -l authPriv -u ${SNMP_USER} -a ${AUTH_PROTOCOL} -x ${PRIV_PROTOCOL} -A ${SNMP_PASSWORD} -X ${SNMP_PASSWORD} ${HOST_ADDRESS}:${SNMP_PORT}"
else
    snmp_base_args="-O qtv -v 2c -c ${SNMP_COMMUNITY} ${HOST_ADDRESS}:${SNMP_PORT}"
fi

link_indexes=($(snmpwalk ${snmp_base_args} ${IF_INDEX_OID}))
output_exit_code=$?

if [ $output_exit_code -gt 0 ]; then
    echo "ERROR: No response from remote host $HOST_ADDRESS, exit code is $output_exit_code"
    exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_ESCAPE = true ]]; then LINE_SEPARATOR="</br>"; fi

cache_file="/tmp/snmp_interface_bandwidth_${HOST_ADDRESS}.cache"
snmp_cmds=("snmpget ${snmp_base_args} ${SYS_UP_TIME_OID} ")
oid_count=1

for index in "${link_indexes[@]}"; do # Prepare snmp command/s to prevent build snmpget bigger than $MAX_OIDS
    for oid in "${OIDS[@]}"; do
        snmp_cmds[${#snmp_cmds[@]} - 1]+="$oid.$index "
        oid_count=$((oid_count + 1))
        
        if [ $(( oid_count % MAX_OIDS)) == 0 ]; then
            snmp_cmds+=("snmpget ${snmp_base_args} ")
        fi
    done
done

for cmd in "${snmp_cmds[@]}"; do
    if [ -z "$snmp_data" ]; then
        mapfile -t snmp_data <<< $($cmd)
    else
        mapfile -t -O "${#snmp_data[@]}" snmp_data <<< $($cmd)
    fi
done

sys_uptime_timeticks=${snmp_data[0]}
unset snmp_data[0]
snmp_data=("${snmp_data[@]}")

cache_data=$(< $cache_file)
new_cache_content="$sys_uptime_timeticks"$'\n'
msg=""

if [[ -n "$cache_data" ]]; then
    cached_sys_uptime_timeticks=$(awk 'NR==1{print; exit}' <<< "$cache_data")

    links_not_ok=0
    links_ok=0
    base_id=0

    for index in "${link_indexes[@]}"; do # snmp_data structure: [(if_name_1, if_state_1, if_in_octets_1, if_out_octets_1) ... (if_name_n, if_state_n, if_in_traffic_n, if_out_traffic_n))
        link_ok=true
        read link_name link_state link_in_octets link_out_octets <<< "${snmp_data[@]:$base_id:4}"

        if [[ $EXCLUDE_PATTERN && $link_name =~ $EXCLUDE_PATTERN ]]; then
            if [[ -n $VERBOSE ]]; then echo "Link $link_name excluded${LINE_SEPARATOR}"; fi
        elif [[ -z $MATCH_PATTERN || $link_name =~ $MATCH_PATTERN ]]; then
            if [[ "$link_state" != *"up"* ]]; then
                links_not_ok=$((links_not_ok + 1))
                msg="${msg}CRITICAL: Link ${link_name} is ${link_state}${LINE_SEPARATOR}"
            else
                read -a cached_link_data <<< "$(awk -v link_index="$index" '$1 == link_index { print $0 }' <<< "$cache_data")"
                cached_link_state=${cached_link_data[2]}
                cached_link_in_octets=${cached_link_data[3]}
                cached_link_out_octets=${cached_link_data[4]}

                # Convert timeticks to seconds, 100 timeticks is 1 second
                seconds_since_cache_data=$(((sys_uptime_timeticks - cached_sys_uptime_timeticks) / 100))
                
                read in_rate_mbps in_formatted_rate in_rate_unit <<< "$(get_traffic_rate "$link_in_octets" "$cached_link_in_octets" "$seconds_since_cache_data")"
                read out_rate_mbps out_formatted_rate out_rate_unit <<< "$(get_traffic_rate "$link_out_octets" "$cached_link_out_octets" "$seconds_since_cache_data")"

                if [[ $in_rate_mbps -gt $CRIT_IN_RATE ]]; then
                    msg="${msg}CRITICAL: Inbound traffic on ${link_name} link is ${in_formatted_rate} ${in_rate_unit} (> ${CRIT_IN_RATE} ${MB_UNIT})${LINE_SEPARATOR}"
                    link_ok=false
                    EXIT_CODE=$NAGIOS_CRIT
                elif [[ $in_rate_mbps -gt $WARN_IN_RATE ]]; then
                    msg="${msg}WARNING: Inbound traffic on ${link_name} link is ${in_formatted_rate} ${in_rate_unit} (> ${WARN_IN_RATE} ${MB_UNIT})${LINE_SEPARATOR}"
                    link_ok=false
                    EXIT_CODE=$NAGIOS_WARN
                elif [[ $SHORT_OUTPUT = false ]]; then
                    msg="${msg}OK: Inbound traffic on ${link_name} link is ${in_formatted_rate} ${in_rate_unit}${LINE_SEPARATOR}"
                    if [[ $EXIT_CODE != $NAGIOS_CRIT && $EXIT_CODE != $NAGIOS_WARN ]]; then EXIT_CODE=$NAGIOS_OK; fi
                fi

                if [[ $out_rate_mbps -gt $CRIT_OUT_RATE ]]; then
                    msg="${msg}CRITICAL: Outbound traffic on ${link_name} link is ${out_formatted_rate} ${out_rate_unit} (> ${CRIT_OUT_RATE} ${MB_UNIT})${LINE_SEPARATOR}"
                    link_ok=false
                    EXIT_CODE=$NAGIOS_CRIT
                elif [[ $out_rate_mbps -gt $WARN_OUT_RATE ]]; then
                    msg="${msg}WARNING: Outbound traffic on ${link_name} link is ${out_formatted_rate} ${out_rate_unit} (> ${WARN_OUT_RATE} ${MB_UNIT})${LINE_SEPARATOR}"
                    link_ok=false
                    if [[ $EXIT_CODE != $NAGIOS_CRIT ]]; then EXIT_CODE=$NAGIOS_WARN; fi
                elif [[ $SHORT_OUTPUT = false ]]; then
                    msg="${msg}OK: Outbound traffic on ${link_name} link is ${out_formatted_rate} ${out_rate_unit}${LINE_SEPARATOR}"
                    if [[ $EXIT_CODE != $NAGIOS_CRIT && $EXIT_CODE != $NAGIOS_WARN ]]; then EXIT_CODE=$NAGIOS_OK; fi
                fi

                if [[ $link_ok = true ]]; then
                    links_ok=$((links_ok + 1))
                else
                    links_not_ok=$((links_not_ok + 1))
                fi
            fi
        else
            if [[ -n $VERBOSE ]]; then echo "Link $link_name not matched to pattern"; fi
        fi
        
        new_cache_content+="$index $link_name $link_state $link_in_octets $link_out_octets\n"
        base_id=$((base_id + ${#OIDS[@]}))
    done
    
    echo -e "$new_cache_content" > $cache_file

    if [ $links_ok -eq 0 ] && [ $links_not_ok -eq 0 ]; then
        echo "ERROR: All links has been excluded from output by /$EXCLUDE_PATTERN/ exclude pattern or not matched by /$MATCH_PATTERN/ match pattern"
        exit $NAGIOS_UNKNOWN
    fi

    if [[ $SHORT_OUTPUT = true ]]; then
        if [[ $links_not_ok -eq 0 ]]; then
            msg="OK: All links ok${LINE_SEPARATOR}${msg}"
        else
            msg="${links_not_ok}/${#link_indexes[@]} links not ok${LINE_SEPARATOR}${msg}"
        fi
    fi

    if [[ $NAGIOS_ESCAPE = true ]]; then echo -e ${msg%?????}; else echo -e ${msg%??}; fi
else
    for index in "${link_indexes[@]}"; do
        read link_name link_state link_in_octets link_out_octets <<< "${snmp_data[@]:$base_id:4}"
        new_cache_content+="$index $link_name $link_state $link_in_octets $link_out_octets\n"
        base_id=$((base_id + ${#OIDS[@]}))
    done

    echo -e "$new_cache_content" > $cache_file
    echo "Cache file not found, script wil re-execute"
    exec "$0" "${ARGS[@]}"
fi

exit $EXIT_CODE
