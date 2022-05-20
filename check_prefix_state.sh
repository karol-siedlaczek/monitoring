#!/bin/bash

# extend script on remote machine

query_output=$(birdc show ro protocol <name4> | grep <name4> | awk '{printf "%s %s %s %s %s %s<br/>", $1, $2, $3, $4, $5, $6}' ; birdc show ro protocol <name6> | grep <name6> | awk '{printf "%s %s %s %s %s %s<br/>", $1, $2, $3, $4, $5, $6}')

if [ -z "$query_output" ]
then
        echo "OK - all prefixes are reachable"
        exit 0
else
        nagios_output=${query_output%?????}
        echo $nagios_output
        exit 2
fi
