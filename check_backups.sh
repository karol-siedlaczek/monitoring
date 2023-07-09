#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
STATUS_CODE=$NAGIOS_OK
DAYS_TO_CHECK=$1
BACKUP_LOG_PATH="/var/log/backup-tool.log"
CATCH_ERROR_REGEX="([0-9]{4}-[0-9]{2}-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}).*ERROR:\sbackup\s.(.*).\sfailed"

since_date=$(date +%Y-%m-%d --date="${DAYS_TO_CHECK} days ago")
log_lines=$(cat $BACKUP_LOG_PATH | awk -vdate="$since_date" '$1 >= date && $4 != "DEBUG"')

while IFS= read -r line
do
        echo $line
        if [[ "$line" =~ $CATCH_ERROR_REGEX ]]
        then
                MSG="${MSG}CRITICAL: backup '${BASH_REMATCH[2]}' has failed at ${BASH_REMATCH[1]}\n"
                STATUS_CODE=$NAGIOS_CRIT
        fi
done <<< "$log_lines"

if [ -z "$MSG" ]
then
        MSG="OK: all backups were successful in last ${DAYS_TO_CHECK} days"
else
        MSG="${MSG}Check logs in '${BACKUP_LOG_PATH}' file"
fi

echo -e $MSG
exit $STATUS_CODE
