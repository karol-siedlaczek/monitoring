#!/bin/bash

usage() {
    cat <<EOT
Usage: `basename $0` [-w|-c|-d|-v]
    -w  warning_threshold
        set warning threshold (default 20)
    -c  critical_threshold
        set critical threshold (default 10)
    -d  device (e.g /dev/sda)
        set device name (default all devices)
    -h  print the help message and exit
EOT
}

# Exit codes
state_ok=0
state_warning=1
state_critical=2
state_unknown=3

# Defaults
warning_threshold="20"
critical_threshold="10"

while getopts "w:c:d:h" opt; do
    case $opt in
        w)
            warning_threshold=$OPTARG
            ;;
        c)
            critical_threshold=$OPTARG
            ;;
        d)
            devices=$OPTARG
            ;;
        *)
            usage
            exit $state_unknown
            ;;
    esac
done

[ -z $devices ] && devices=$(awk '$4 ~ /^[a-z]d[a-z]+$/ {print "/dev/"$4}' /proc/partitions)

smartctl=$(which smartctl)
[ -x "$smartctl" ] || {
    echo "UNKNOWN: smartctl - commant not found"
    exit $state_unknown
}

for dev in $devices; do
    val=$($smartctl -A $dev -d auto | awk '$1==5 {print $NF}')

    if [[ $val -gt $critical_threshold ]]; then
        exitstatus=$state_critical
        msg="${msg}CRITICAL: ${val} bad sector/s on ${dev} device\n"
    elif [[ $val -gt $warning_threshold ]]; then
        [ "$exitstatus" == $state_critical ] || exitstatus=$state_warning
        msg="${msg}WARNING: ${val} bad sector/s on ${dev} device\n"
    elif [ -n "$val" ]; then
        [ -n "$exitstatus" ] || exitstatus=$state_ok
        msg="${msg}OK: ${val} bad sector/s on ${dev} device\n"
    # else (if wanna more data)
    #     is_device_support_smart=$($smartctl -A $dev -d auto | grep '=== START OF READ SMART DATA SECTION ===')
    #     if [ -n "$is_device_support_smart" ]; then
    #         [ -n "$exitstatus" ] || exitstatus=$state_ok
    #         info="${info}(OK - DEVICE NOT SUPPORT SMART-ID:5) "
    #     else
    #         [ -n "$exitstatus" ] || exitstatus=$state_unknown
    #         info="${info}(UNKNOWN - DEVICE NOT SUPPORT SMART) "
    #     fi
    fi
done

echo ${msg%??}
exit $exitstatus
