#!/bin/bash

health_status=$(/usr/bin/sudo ceph health)
exit_code=$?

if [[ "$health_status" == *"HEALTH_OK"* ]]
then
    exit_code=0
elif [[ "$health_status" == *"HEALTH_WARN"* ]]
then
    exit_code=1
elif [[ "$health_status" == *"HEALTH_CRIT"* || "$health_status" == *"HEALTH_ERR"* ]]
then
    exit_code=2
fi

echo $health_status

if [ $exit_code -gt 3 ]
then
    exit 3
else
    exit $exit_code
fi
