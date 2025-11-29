#!/bin/bash

# Karol Siedlaczek 2025

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
NAGIOS_ESCAPE=false
LINE_SEPARATOR="\n"

while getopts g:n flag
do
  case "${flag}" in
    g) GOVERNOR=${OPTARG};;
    n) NAGIOS_ESCAPE=true;;
  esac
done

if [[ -z "$GOVERNOR" ]]; then
    echo "Usage: $0 -g <CPU_FREQUENCY_SCALING_GOVERNOR>"
    exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_ESCAPE = true ]]; then LINE_SEPARATOR="</br>"; fi

shopt -s nullglob
cpufreq_paths=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq)

if [[ ${#cpufreq_paths[@]} -eq 0 ]]; then
    echo "UNKNOWN: No 'sys/devices/system/cpu/cpu*/cpufreq' directories found"
    exit $NAGIOS_UNKNOWN
fi

scaling_governor_ok=true
max_freq_ok=true

for cpufreq_path in "${cpufreq_paths[@]}"; do
    cpuinfo_max_freq=$(< "$cpufreq_path/cpuinfo_max_freq")
    scaling_max_freq=$(< "$cpufreq_path/scaling_max_freq")
    scaling_governor=$(< "$cpufreq_path/scaling_governor")

    if [[ "$scaling_governor" != "$GOVERNOR" ]]; then
        scaling_governor_ok=false
    fi
    if [[ $scaling_max_freq != $cpuinfo_max_freq ]]; then
        max_freq_ok=false
    fi
done

msg=""

if [[ $scaling_governor_ok = true ]]; then
    msg="OK: Frequency scaling is '$GOVERNOR' for all cores$LINE_SEPARATOR"
    EXIT_CODE=$NAGIOS_OK
else
    msg="CRITICAL: Frequency scaling is not '$GOVERNOR' for all cores$LINE_SEPARATOR"
    EXIT_CODE=$NAGIOS_CRIT
fi

if [[ $max_freq_ok = true ]]; then
    msg="${msg}OK: CPU max frequency is equal to scaling max frequency for all cores"
else
    msg="${msg}CRITICAL: CPU max frequency and scaling max frequency is not equal for all cores"
    EXIT_CODE=$NAGIOS_CRIT
fi

echo -e $msg
exit $EXIT_CODE
