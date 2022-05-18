#!/bin/bash

MAIL_RECIPIENT=user@example.com
TMP_FILE=".check_prefix_state"

prefixes_state=$(birdc show ro protocol <name4> | grep <name4> | awk '{printf "%s %s %s %s %s %s<br/>", $1, $2, $3, $4, $5, $6}' ; birdc show ro protocol <name6> | grep <name6> | awk '{printf "%s %s %s %s %s %s<br/>", $1, $2, $3, $4, $5, $6}')

if [ ! -f "/tmp/$TMP_FILE" ]
then
    touch "/tmp/$TMP_FILE"
fi

if [ -z "$prefixes_state" ]
then
        echo "OK - all prefixes are reachable"
        echo OK > "/tmp/${TMP_FILE}"
        exit 0
else
        state=$(cat "/tmp/$TMP_FILE")
        if [ "$state" != "CRITICAL" ]
        then
                mail_output=${prefixes_state//<br\/>/\\n}
                echo -e ${mail_output} | mail -s "prefix state alert" ${MAIL_RECIPIENT}
                echo CRITICAL > "/tmp/${TMP_FILE}"
        fi
        nagios_output=${prefixes_state%?????}
        echo ${nagios_output}
        exit 2
fi

