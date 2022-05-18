#!/bin/bash

MAIL_RECIPIENT=user@example.com
TMP_FILE=".check_bgp_session_state"

sessions_state=$(birdc show protocols | awk '{if ($2=="BGP" && $4!="up") {x == ""; for (i=6; i <= NF; i++) x= x $i " "; printf "%s, state: %s, info: %s<br/>", $1, $4, x}; x=""}')

if [ ! -f "/tmp/$TMP_FILE" ]
then
    touch "/tmp/$TMP_FILE"
fi

if [ -z "$sessions_state" ]
then
        echo "OK - all sessions are up"
        echo OK > "/tmp/${TMP_FILE}"
        exit 0
else
        state=$(cat "/tmp/$TMP_FILE")
        if [ "$state" != "CRITICAL" ]
        then
                mail_output=${sessions_state//<br\/>/\\n}
                echo -e ${mail_output} | mail -s "BGP session alert" ${MAIL_RECIPIENT}
                echo CRITICAL > "/tmp/${TMP_FILE}"
        fi
        nagios_output=${sessions_state%?????}
        echo ${nagios_output}
        exit 2
fi
