#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_OK
DELIMITER="\n"

while getopts n flag
do
case "${flag}" in
    n) NAGIOS_OUTPUT=true;;
esac
done

slave_status=$(mysql -u root -e "SHOW SLAVE STATUS\G")

if [ $? -gt 0 ]; then
    echo "CRITICAL: $slave_status"
    exit $NAGIOS_CRIT
elif [[ -z $slave_status ]]; then
    echo "UNKNOWN: No replication configured (host is master)"
    exit $NAGIOS_UNKNOWN
fi

if [[ $NAGIOS_OUTPUT = true ]]; then DELIMITER="</br>"; fi

seconds_behind=$(echo "$slave_status" | awk -F ': ' '/Seconds_Behind_Master:/ {print $2}')
slave_io=$(echo "$slave_status" | awk -F ': ' '/Slave_IO_Running:/ {print $2}')
slave_sql=$(echo "$slave_status" | awk -F ': ' '/Slave_SQL_Running:/ {print $2}')
master_log=$(echo "$slave_status" | awk -F ': ' '/ Master_Log_File:/ {print $2}')
relay_log=$(echo "$slave_status" | awk -F ': ' '/Relay_Master_Log_File:/ {print $2}')

if [ $seconds_behind -gt 60 ]; then
    state="CRITICAL"
    EXIT_CODE=$NAGIOS_CRIT
elif [ $seconds_behind -gt 30 ]; then
    state="WARNING"
    EXIT_CODE=$NAGIOS_WARN
else
    state="OK"
fi

msg="$state: Replica is $seconds_behind second/s behind master$DELIMITER"

if [ $slave_io != "Yes" ]; then
    state="CRITICAL"
    EXIT_CODE=$NAGIOS_CRIT
else
    state="OK"
fi

msg="${msg}$state: Slave IO running: $slave_io$DELIMITER"

if [ $slave_sql != "Yes" ]; then
    state="CRITICAL"
    EXIT_CODE=$NAGIOS_CRIT
else
    state="OK"
fi

msg="${msg}$state: Slave SQL running: $slave_io$DELIMITER"

if [ $master_log != $relay_log ]; then
    msg="${msg}WARNING: Master log file mismatch $master_log (master) != $relay_log (relay)"
    if [[ $EXIT_CODE -lt $NAGIOS_WARN ]]; then EXIT_CODE=$NAGIOS_WARN; fi
else
    msg="${msg}OK: Master log files matches, $master_log (master) == $relay_log (relay)"
fi

echo -e $msg
exit $EXIT_CODE
