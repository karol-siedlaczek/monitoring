#!/bin/bash

CODE_OK=0
CODE_WARN=1
CODE_CRIT=2
CODE_UNKNOWN=3
EXIT_CODE=$CODE_OK

function HELP {
    echo "DESCRIPTION"
    echo -e "Check Postfix mail queue size\n"

    echo "USAGE"
    echo "  -w=INT      Warning level for messages in queue (required)"
    echo "  -c=INT      Critical level for messages in queue (required)"
    echo "  -C=STRING   Docker container name"
    echo "  -h          Show this help message and exit"
    exit $CODE_UNKNOWN
}

while getopts w:c:C flag; do
case "${flag}" in
    w) WARN=${OPTARG};;
    c) CRIT=${OPTARG};;
    C) CONTAINER=${OPTARG};;
    *) HELP;;
esac
done

if [[ -z $WARN || -z $CRIT || -z $CONTAINER]]; then
    HELP
fi

queue_size=$(docker exec $CONTAINER mailq | egrep -c '^[A-F0-9]{10}')

if [ -z $queue_size ]; then
    msg="UNKNOWN: Cannot determine mail queue size"
    EXIT_CODE=$CODE_UNKNOWN
elif [ $queue_size -gt $CRIT ]; then
    msg="CRITICAL: $queue_size messages in queue (>$CRIT)"
    EXIT_CODE=$CODE_CRIT
elif [ $queue_size -gt $WARN ]; then
    msg="WARNING: $queue_size messages in queue (>$WARN)"
    EXIT_CODE=$CODE_WARN
else
    msg="OK: $queue_size messages in queue"
    EXIT_CODE=$CODE_OK
fi

echo $msg
exit $EXIT_CODE
