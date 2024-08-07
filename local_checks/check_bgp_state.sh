#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_CRIT
MAX_DIFF_SEC=$1 # max difference (in secs) which raise critical about flapping, if session is UP less than <MAX_DIFF_SEC> seconds check will return critical

if [[ -z "$MAX_DIFF_SEC" ]]
then
        echo "Usage: $0 <MAX_DIFF_SEC>"
        exit $NAGIOS_UNKNOWN
fi

check_since_dates () {
        bfd_sessions_state=$1
        curr_date_sec=$(date +%s)
        sessions_num=0
        sessions_flapped=0
        while IFS= read -r line
        do
                sessions_num=$((sessions_num + 1))
                ip_addr=$(echo "$line" | awk '{print $1}')
                since_date=$(echo "$line" | awk '{print $4}')
                since_date_sec=$(date --date="$since_date" +%s)
                curr_since_date_diff=$((curr_date_sec - since_date_sec))
                if [ $curr_since_date_diff -le $MAX_DIFF_SEC  ] && ([ $curr_since_date_diff -gt 0 ] || [ $curr_since_date_diff -le $((-86400 + MAX_DIFF_SEC)) ]) # -gt 0 to prevent checking dates from not current day
                then
                        sessions_flapped=$((sessions_flapped + 1))
                        if [ $curr_since_date_diff -lt 0 ]; then curr_since_date_diff=$(($curr_since_date_diff + 86400)); fi
                        MSG="${MSG}<STATE_MARKER>: BGP session with ${ip_addr} address changed state ${curr_since_date_diff} seconds ago ($since_date)</br>"
                fi
        done <<< "$bfd_sessions_state"
        if [ $sessions_num -eq $sessions_flapped ]
        then
                EXIT_CODE=$NAGIOS_CRIT
                MSG=${MSG//<STATE_MARKER>/CRITICAL}
        elif [ $sessions_flapped -gt 0 ]
        then
                EXIT_CODE=$NAGIOS_WARN
                MSG=${MSG//<STATE_MARKER>/WARNING}
        fi
}

bfd_sessions_state=$(birdc show bfd sessions | awk '($3=="Up" && NR > 3)')
down_sessions=$(birdc show bfd sessions | awk '{if ($3!="Up" && NR > 3) {x == ""; for (i=6; i <= NF; i++) x= x $i " "; printf "CRITICAL: BGP session with %s address is in %s state since %s</br>", $1, $3, $4 x}; x=""}')

if [ -z "$down_sessions" ]
then
        birdc show proto >/dev/null && EXIT_CODE=$NAGIOS_OK || EXIT_CODE=$NAGIOS_CRIT
        if [[ $EXIT_CODE == $NAGIOS_OK ]]
        then
                check_since_dates "$bfd_sessions_state"
                MSG="${MSG}OK: all sessions are up"
        fi
else
        check_since_dates "$bfd_sessions_state"
        MSG="${MSG}${down_sessions%?????}"
        EXIT_CODE=$NAGIOS_CRIT
fi

echo -e $MSG
exit $EXIT_CODE
