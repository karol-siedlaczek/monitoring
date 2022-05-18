#!/bin/bash

MAIL_RECIPIENT=user@example.com
NOTIFICATION_DELAY="30 minutes ago"
TMP_FILE=".bgp_session_last_msg_id"

sessions_state=$(birdc show protocols | awk '{if ($2=="BGP" && $4!="up") {x == ""; for (i=6; i <= NF; i++) x= x $i " "; printf "%s, state: %s, info: %s<br/>\n", $1, $4, x}; x=""}')

if [ -z "$sessions_state" ]
then
	echo "OK - all sessions are up"
	exit 0
else
	last_mail_id=$(cat "/tmp/$TMP_FILE")
	last_mail_datetime=$(tail -n +1 /var/log/exim4/mainlog | grep "=> ${MAIL_RECIPIENT}" | awk '$3 ~ /'${last_mail_id}'/ {printf "%s %s\n", $1, $2}')
	mail_timestamp=$(date --date "$last_mail_datetime" +'%s')
	delay_timestamp=$(date --date "$NOTIFICATION_DELAY" +'%s')
	if [[ $mail_timestamp < $delay_timestamp ]]
	then
		mail_output=${sessions_state//<br\/>/}
		echo "${mail_output}" | mail -s "BGP session alert" ${MAIL_RECIPIENT}
		msg_id=$(tail -n +1 /var/log/exim4/mainlog | grep "=> ${MAIL_RECIPIENT}" | awk '{printf "%s\n", $3}' | tail -n 1)
		echo ${msg_id} > "/tmp/${TMP_FILE}"
	fi
	nagios_output=${sessions_state%?????}
	echo "${nagios_output}"
	exit 2
fi
