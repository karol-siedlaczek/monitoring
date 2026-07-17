#!/bin/bash

CODE_OK=0
CODE_WARN=1
CODE_CRIT=2
CODE_UNKNOWN=3
EXIT_CODE=$CODE_OK

function HELP {
    echo "DESCRIPTION"
    echo -e "Check child process (connection) usage in pgpool\n"

    echo "USAGE"
    echo "  -w=INT    Warning level for connections in percent (required)"
    echo "  -c=INT    Critical level for connections in percent (required)"
    echo "  -h        Show this help message and exit"
    exit $CODE_UNKNOWN
}

while getopts w:c:h flag; do
case "${flag}" in
    w) WARN=${OPTARG};;
    c) CRIT=${OPTARG};;
    *) HELP;;
esac
done

if [[ -z $WARN || -z $CRIT ]]; then
    HELP
fi

if ! pgrep -x pgpool > /dev/null; then
    echo "CRITICAL: pgpool process not running"
    exit $CODE_CRIT
fi

handlers=$(ps -eo args= | grep -E '^pgpool: ' | grep -Ev 'PCP:|worker process|health check|watchdog|logger|follow child|pcp child|main process')

max_connections=$(echo "$handlers" | grep -c .)
if [[ $max_connections -eq 0 ]]; then
    echo "UNKNOWN: No pgpool child processes found"
    exit $CODE_UNKNOWN
fi

idle_connections=$(echo "$handlers" | grep -c 'wait for connection')
connections=$((max_connections - idle_connections))

connections_percentage=$((connections * 100 / max_connections))

if [[ $connections_percentage -ge $CRIT ]]; then
    echo "CRITICAL: High connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit $CODE_CRIT
elif [[ $connections_percentage -ge $WARN ]]; then
    echo "WARNING: High connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit $CODE_WARN
else
    echo "OK: Connection pool usage: $connections/$max_connections ($connections_percentage%)"
    exit $CODE_OK
fi
