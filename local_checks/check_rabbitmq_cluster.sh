#!/bin/bash

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

CLUSTER_SIZE=$1

if [[ -z "$CLUSTER_SIZE" ]]
then
   echo -e "Syntax error\nUsage: $0 <CLUSTER_SIZE>"
   exit $NAGIOS_UNKNOWN
fi

rabbitmq_lxc=$(lxc-ls -1 --running | awk '/.*rabbit_mq.*/ {print; exit}')
running_nodes_count=$(lxc-attach $rabbitmq_lxc -- rabbitmqctl cluster_status --formatter json | jq '.running_nodes | length')

if [[ $running_nodes_count -eq $CLUSTER_SIZE ]]; then
    MSG="OK: RabbitMQ cluster is running with $running_nodes_count/$CLUSTER_SIZE nodes"
    EXIT_CODE=$NAGIOS_OK
else
    MSG="CRITICAL: RabbitMQ cluster size mismatch $running_nodes_count/$CLUSTER_SIZE"
    EXIT_CODE=$NAGIOS_CRIT
fi

cluster_alarms=$(lxc-attach $rabbitmq_lxc -- rabbitmqctl cluster_status --formatter json | jq .alarms)

if [[ "$cluster_alarms" != "[]" ]]; then
    MSG="$MSG</br>CRITICAL: Detected alarms in cluster: $cluster_alarms"
    EXIT_CODE=$NAGIOS_CRIT
fi

echo -e $MSG
exit $EXIT_CODE
