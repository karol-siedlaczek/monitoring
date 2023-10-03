#!/bin/bash

while IFS= read -r host; do
    # Submit passive check result for each host
    printf "[%lu] PROCESS_HOST_CHECK_RESULT;$host;1;FORCE CRITICAL\n" $(date +%s) >> /var/lib/nagios4/rw/nagios.cmd
    echo "Set $host status to DOWN"
done < "host_list.txt"