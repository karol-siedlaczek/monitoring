#!/bin/bash

PATH_TO_CHECK=$1
MAX_SIZE=$2 # Megabytes
EXIT_CODE=2

SIZE=$(du -sm --exclude $PATH_TO_CHECK/cache $PATH_TO_CHECK | awk '{ print $1 }')

if [ $SIZE -gt $MAX_SIZE ]
then
        EXIT_CODE=1
        MSG="WARNING: (>$MAX_SIZE MB) $PATH_TO_CHECK: $SIZE MB"
else
        MSG="OK: (<$MAX_SIZE MB) $PATH_TO_CHECK: $SIZE MB"
        EXIT_CODE=0
fi

echo $MSG
exit $EXIT_CODE