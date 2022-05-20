#!/bin/bash

# extend script on remote machine

query_output=$(birdc show protocols | awk '{if ($2=="BGP" && $4!="up") {x == ""; for (i=6; i <= NF; i++) x= x $i " "; printf "%s, state: %s, info: %s<br/>", $1, $4, x}; x=""}')

if [ -z "$query_output" ]
then
        echo "OK - all sessions are up"
        exit 0
else
        nagios_output=${query_output%?????}
        echo $nagios_output
        exit 2
fi
