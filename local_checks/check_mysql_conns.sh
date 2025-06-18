#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
EXIT_CODE=$NAGIOS_OK

function HELP {
  echo "DESCRIPTION"
  echo -e "Check connections in mysql"\\n
  echo "USAGE"
  echo "  -w=INT    Warning level for connections in percent (required)"
  echo "  -c=INT    Critical level for connections in percent  (required)"
  echo "  -h        Show this help message and exit"
  exit 1
}

while getopts w:c:n flag
do
case "${flag}" in
    w) WARN=${OPTARG};;
    c) CRIT=${OPTARG};;
    *) HELP;;
esac
done

if [[ -z $WARN || -z $CRIT ]]; then
    HELP
fi

max_connections=$(mysql  -u root -e "show variables like 'max_connections'\G;")
if [ $? -gt 0 ]; then
    echo $max_connections
    exit $NAGIOS_CRIT
fi
max_connections=$(echo "$max_connections" | awk -F ': ' '/Value:/ {print $2}')

connections=$(mysql -e "show status where \`variable_name\` in ('Threads_connected')\G;")
if [ $? -gt 0 ]; then
    echo $connections
    exit $NAGIOS_CRIT
fi
connections=$(echo "$connections" | awk -F ': ' '/Value:/ {print $2}')

connections_percentage=$[$connections*100/$max_connections]

if [[ $connections_percentage -ge $CRIT ]]; then
    echo "CRITICAL: High connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit 2
elif [[ $connections_percentage -ge $WARN ]]; then
    echo "WARNING: High connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit 1
else
    echo "OK: Connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit 0
fi
