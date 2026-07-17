#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

RABBIT_HOST=$1
RABBIT_PORT=$2
RABBIT_USER=$3
RABBIT_PASS=$4
WARN_MESSAGES_IN_QUEUE=$5
CRIT_MESSAGES_IN_QUEUE=$6

if [[ -z "$RABBIT_HOST" || -z "$RABBIT_USER" || -z "$RABBIT_PASS" || -z "$WARN_MESSAGES_IN_QUEUE" || -z "$CRIT_MESSAGES_IN_QUEUE" ]]
then
   echo -e "Syntax error\nUsage: $0 <RABBIT_HOST> <RABBIT_PORT> <RABBIT_USER> <RABBIT_PASS> <WARN_MESSAGES_IN_QUEUE> <CRIT_MESSAGES_IN_QUEUE>"
   exit $NAGIOS_UNKNOWN
fi

curl_output=$(curl -s --noproxy '*' --fail --show-error https://${RABBIT_USER}:${RABBIT_PASS}@${RABBIT_HOST}:${RABBIT_PORT}/api/overview 2>&1)

curl_exit_code=$?

if [ $curl_exit_code -gt 0 ]; then
   echo "ERROR: ${curl_output}"
   exit $NAGIOS_CRIT
fi

queue_total_messages=$(echo $curl_output | jq .queue_totals.messages)

message_stats_get_no_ack=$(echo $curl_output | jq .message_stats.get_no_ack)
message_stats_deliver_no_ack=$(echo $curl_output | jq .message_stats.deliver_no_ack)

if [[ $queue_total_messages == +([[:digit:]]) && $message_stats_get_no_ack == +([[:digit:]]) && $message_stats_deliver_no_ack == +([[:digit:]]) ]]; then 
    if [[ $queue_total_messages -ge $CRIT_MESSAGES_IN_QUEUE ]]; then
        msg="CRITICAL: ${queue_total_messages} messages in queue (>${CRIT_MESSAGES_IN_QUEUE})</br>"
        exit_code=2;
    elif [[ $queue_total_messages -ge $WARN_MESSAGES_IN_QUEUE ]]; then
        msg="WARNING: ${queue_total_messages} messages in queue (>${WARN_MESSAGES_IN_QUEUE})</br>"
        exit_code=1;
    else
        msg="OK: ${queue_total_messages} messages in queue</br>"
        exit_code=$NAGIOS_OK
    fi

    if [[ $message_stats_get_no_ack -gt 0 ]]; then
        msg+="CRITICAL: ${message_stats_get_no_ack} get_no_ack messages</br>"
        exit_code=$NAGIOS_CRIT
    else
        msg+="OK: No found any get_no_ack message</br>"
    fi

    if [[ $message_stats_deliver_no_ack -gt 0 ]]; then
        msg+="CRITICAL: ${message_stats_deliver_no_ack} deliver_no_ack messages"
        exit_code=$NAGIOS_CRIT
    else
        msg+="OK: No found any deliver_no_ack message"
    fi
else
   MSG="ERROR: Values are not valid digits to calculate usage: queue_total_messages=${queue_total_messages}, message_stats_get_no_ack=${message_stats_get_no_ack}, message_stats_deliver_no_ack=${message_stats_deliver_no_ack}"
   EXIT_CODE=$NAGIOS_CRIT
fi

echo -e $msg
exit $exit_code
