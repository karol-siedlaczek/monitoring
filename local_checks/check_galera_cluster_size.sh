#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=2
EXIT_CODE=$NAGIOS_OK

EXPECTED_CLUSTER_SIZE=$1

if [[ -z "$EXPECTED_CLUSTER_SIZE" ]]
then
   echo -e "Syntax error\nUsage: $0 <CLUSTER_SIZE>"
   exit $NAGIOS_UNKNOWN
fi

cluster_size=$(mysql -e "show status where \`variable_name\` in ('wsrep_cluster_size')\G")

if [ $? -gt 0 ]; then
    echo "CRITICAL: $cluster_size"
    exit $NAGIOS_CRIT
fi

cluster_size=$(echo "$cluster_size" | awk -F ': ' '/Value:/ {print $2}')

if [[ $cluster_size -lt $EXPECTED_CLUSTER_SIZE ]]; then
    echo "CRITICAL: Cluster size mismatch $cluster_size/$EXPECTED_CLUSTER_SIZE"
    exit $NAGIOS_CRIT
elif [[ $cluster_size -gt $EXPECTED_CLUSTER_SIZE ]]; then
    echo "WARNING: Cluster size mismatch $cluster_size/$EXPECTED_CLUSTER_SIZE"
    exit $NAGIOS_WARN
else
    echo "OK: Cluster size $cluster_size/$EXPECTED_CLUSTER_SIZE"
    exit $NAGIOS_OK
fi
