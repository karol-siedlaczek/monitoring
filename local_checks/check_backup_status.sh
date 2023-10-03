#!/bin/bash

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
STATUS_CODE=$NAGIOS_OK
CATCH_ERROR_REGEX="([0-9]{4}-[0-9]{2}-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}).*ERROR\sbackup\s.(.*backup-[0-9]{4}-[0-9]{2}-[0-9]{2})"
LOG_FILE=$1
DAYS_TO_CHECK=$2

if [[ -z "$LOG_FILE" || -z "$DAYS_TO_CHECK" ]]
then
   echo "Usage: $0 <LOG_FILE> <DAYS_TO_CHECK>" >&2
   exit $NAGIOS_UNKNOWN
fi

if [ ! -f $LOG_FILE ]
then
        MSG="UNKNOWN: ${LOG_FILE} no such log file"
        STATUS_CODE=$NAGIOS_UNKNOWN
fi

since_date=$(date +%Y-%m-%d --date="${DAYS_TO_CHECK} days ago")
output=$(cat $LOG_FILE | awk -vdate="$since_date" '$1 >= date && $4 != "DEBUG"')

while IFS= read -r line
do
        if [[ "$line" =~ $CATCH_ERROR_REGEX ]]
        then
                MSG="${MSG}CRITICAL: backup '${BASH_REMATCH[2]}' has failed at ${BASH_REMATCH[1]}</br>"
                STATUS_CODE=$NAGIOS_CRIT
        fi
done <<< "$output"

if [ -z "$MSG" ]
then
        MSG="OK: all backups were successful in last ${DAYS_TO_CHECK} days"
elif [[ $STATUS_CODE -eq $NAGIOS_CRIT ]]
then
        MSG="${MSG}Check logs in '${LOG_FILE}' file"
fi

echo -e $MSG
exit $STATUS_CODE