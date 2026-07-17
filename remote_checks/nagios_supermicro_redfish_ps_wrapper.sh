#!/bin/bash
 
# nagios_supermicro_redfish PS wrapper for HP iLO
# strips warnings for non-existent PSUs
 
HOSTADDRESS=$1
USERNAME=$2
PASSWORD=$3
 
# Wrapper
CMD=$(/usr/local/bin/nagios/checks/nagios_supermicro_redfish/bin/nagios_supermicro_redfish \
    -i $HOSTADDRESS \
    -u $USERNAME \
    -p $PASSWORD \
    check -t ps)
 
# Check if we have any output
if [[ ! "$CMD" ]]; then
    echo "UNKNOWN: no output" ; exit 3
fi
 
# Check for any OK PSU
ANY_OK=$(echo "$CMD" | grep ^OK)
 
if [[ ! "$ANY_OK" ]]; then
    echo "$CMD" ; exit 2
fi
 
# Strip non-existent PSUs
echo "$CMD" | head -n 2 | while read -r PS ; do
 
        IS_OK=$(echo $PS | grep ^OK)
 
        if [[ "$IS_OK" ]]; then
            echo $IS_OK
        else
            echo $PS ; exit 2
        fi
 
    done
