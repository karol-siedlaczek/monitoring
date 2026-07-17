#!/bin/bash

CODE_OK=0
CODE_WARN=1
CODE_CRIT=2
CODE_UNKNOWN=3
EXIT_CODE=$CODE_OK

PG_OS_USER=postgres

function HELP {
    echo "DESCRIPTION"
    echo -e "Check connections in PostgreSQL\n"

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

cd / || exit $CODE_UNKNOWN

PSQL=(runuser -u "$PG_OS_USER" -- psql -At -d postgres)

max_connections=$("${PSQL[@]}" -c "SHOW max_connections;" 2>&1)
if ! [[ $max_connections =~ ^[0-9]+$ ]]; then
    echo "CRITICAL: $max_connections"
    exit $CODE_CRIT
fi

connections=$("${PSQL[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend';" 2>&1)
if ! [[ $connections =~ ^[0-9]+$ ]]; then
    echo "CRITICAL: $connections"
    exit $CODE_CRIT
fi

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
