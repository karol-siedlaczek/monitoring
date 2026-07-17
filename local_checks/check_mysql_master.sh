#!/bin/bash

CODE_OK=0
CODE_CRIT=2

read_only=$(mysql -u root -e "show VARIABLES LIKE 'read_only'\G" | awk -F ': ' '/Value:/ {print $2}')

if [[ "$read_only" == "OFF" ]]; then
    echo "OK: Node accepts writes (read_only=OFF)"
    exit $CODE_OK
elif [[ "$read_only" == "ON" ]]; then
    echo "CRITICAL: Node is in read-only mode (read_only=ON)"
    exit $CODE_CRIT
else
    echo "CRITICAL: Unable to determine read_only status (value=$read_only)"
    exit $CODE_CRIT
fi
