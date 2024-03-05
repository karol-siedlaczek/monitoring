#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <file_name> with Hosts names"
    exit 1
fi

file_name=$1

if [ ! -f "$file_name" ]; then
    echo "Error: File '$file_name' not found."
    exit 1
fi

objects_cache_file="/var/lib/nagios4/objects.cache"

while IFS= read -r host; do

    printf "[%lu] PROCESS_HOST_CHECK_RESULT;$host;1;FORCE CRITICAL\n" $(date +%s) >> /var/lib/nagios4/rw/nagios.cmd
    echo "Set $host status to DOWN"

    # Get services for the host
    services=$(grep -E -A 5 "host_name[[:space:]]+$host" "$objects_cache_file" | grep "service_description" | sed 's/^[[:space:]]*service_description[[:space:]]*//')

    if [ -z "$services" ]; then
        echo "No services found for host $host."
    else
        echo "Services for host $host:"
        echo "$services"
	echo ""

        while IFS= read -r service; do
            printf "[%lu] PROCESS_SERVICE_CHECK_RESULT;$host;$service;2;FORCE CRITICAL\n" $(date +%s) >> /var/lib/nagios4/rw/nagios.cmd
            echo "Set $host $service status to CRITICAL"
        done <<< "$services"
    fi
done < "$file_name"
