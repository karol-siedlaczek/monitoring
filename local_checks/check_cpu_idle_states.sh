#!/bin/bash

# Karol Siedlaczek 2025

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
NAGIOS_ESCAPE=false
LINE_SEPARATOR="\n"

is_in_disabled_states() {
    local name="$1"
    for disabled in "${DISABLED_IDLE_STATES[@]}"; do
        if [[ "$disabled" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

while getopts s:n flag
do
  case "${flag}" in
    s) IFS=',' read -r -a DISABLED_IDLE_STATES <<< "${OPTARG}" ;;
    n) NAGIOS_ESCAPE=true;;
  esac
done

if [[ -z "$DISABLED_IDLE_STATES" ]]; then
    echo "Usage: $0 -s <DISABLED_IDLE_STATES>"
    exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_ESCAPE = true ]]; then LINE_SEPARATOR="</br>"; fi

shopt -s nullglob
cpuidle_paths=(/sys/devices/system/cpu/cpu[0-9]*/cpuidle)

if [[ ${#cpuidle_paths[@]} -eq 0 ]]; then
    echo "UNKNOWN: No 'sys/devices/system/cpu/cpu*/cpuidle' directories found"
    exit $NAGIOS_UNKNOWN
fi

declare -A checked_states

for cpuidle_path in "${cpuidle_paths[@]}"; do
    for idle_state_path in "$cpuidle_path"/state[0-9]*; do
        state_disabled=$(< "$idle_state_path/disable")
        state_name=$(< "$idle_state_path/name")

		if is_in_disabled_states "$state_name" && [[ $state_disabled -ne 1 ]]; then
			if [[ -z "${checked_states[$state_name]}" ]]; then
				msg="${msg}WARNING: CPU idle state $state_name is enabled$LINE_SEPARATOR"
				checked_states["$state_name"]=1
				EXIT_CODE=$NAGIOS_WARN
			fi
		fi
    done
done

if [[ -n $msg ]]; then
	if [[ $NAGIOS_ESCAPE = true ]]; then echo -e ${msg%?????}; else echo -e ${msg%??}; fi
	exit $EXIT_CODE
else
	echo -e "OK: CPU idle state/s '${DISABLED_IDLE_STATES[@]}' not enabled"
	exit $NAGIOS_OK
fi
