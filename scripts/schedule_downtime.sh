#!/bin/bash
# Usage: ./schedule_downtime.sh <hosts_file> <start_datetime> <end_datetime>

hosts_file=$1
start_datetime=$2
end_datetime=$3

if [[ -z $hosts_file ]]; then
  hosts_file="/etc/nagios{{ nagios.version }}/scheduled_downtime_hosts.txt"
fi
if [[ -z $start_datetime ]]; then
  start_datetime=$(date +"%Y-%m-%d %H:%M:%S")
fi

if [[ -z $end_datetime ]]; then
  end_datetime=$(date --date="+1000 days" +"%Y-%m-%d %H:%M:%S")
fi

start_time=$(date -d "$start_datetime" +%s)
end_time=$(date -d "$end_datetime" +%s)

if [[ $end_time -lt $start_time ]]; then
   echo "start_datetime is larger than end_datetime - $start_datetime (start) > $end_datetime (end)"
   exit 1
fi

cmd_file='/var/lib/nagios4/rw/nagios.cmd'
common_args="1;0;7200;nagios;Downtime scheduled by script\n"

while IFS= read -r host
do
  now=$(date +%s)
  /bin/printf "[%lu] SCHEDULE_HOST_DOWNTIME;$host;$start_time;$end_time;$common_args" "$now" >> $cmd_file
  /bin/printf "[%lu] SCHEDULE_HOST_SVC_DOWNTIME;$host;$start_time;$end_time;$common_args" "$now" >> $cmd_file
  echo "Downtime scheduled for '$host' host and all services"
done < "$hosts_file"

exit 0

