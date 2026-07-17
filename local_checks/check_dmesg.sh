#!/bin/bash

CODE_OK=0
CODE_WARN=1
CODE_CRIT=2
CODE_UNKNOWN=3
EXIT_CODE=$CODE_UNKNOWN

# TODO dmesg: unrecognized option '--since' 
# tmp grep
GREP_OUT="\(Mounting\|was not properly dismounted\|Trying to mount\|DMA limited to\|Filesystem is not clean\|out of memory in start\|GEOM_\|logical blocks\|physical blocks\|Write Protect\|Mode Sense\|Write cache:\|Attached SCSI\)"

# Defaults
warn=5
crit=10
levels="err,crit,alert"

function HELP {
    echo "Usage: $0 [-h] -d <disk> -i <identifier> [-v] -w <warn> -c <crit> -m <minutes_ago>"
    echo ""
    echo "Check dmesg on selected level"
    echo ""
    echo -w "Message count to raise critical, default is $warn"
    echo ""
    echo -c "Message count to raise warning, default is $crit"
    echo ""
    echo -m "Minutes to specify since time"
    echo ""
    echo -l "Log levels to filter, default is '$levels'"
}

while getopts w:c:m:l:h flag
do
  case "${flag}" in
    w)
      warn=${OPTARG};;
    c)
      crit=${OPTARG};;
    m)
      minutes=${OPTARG};;
    l)
      levels=${OPTARG};;
    *)
      HELP;;
  esac
done

since_date=$(date "+%Y-%m-%d %H:%M:%S" --date="$minutes minutes ago")
mapfile -t output <<< $(dmesg --since "$since_date" --time-format ctime -l $levels)
exit_code=$?

if [ $exit_code -gt 0 ]
then
    echo "ERROR: Unknown exit code $exit_code"
    exit $CODE_UNKNOWN
elif [ -z "$output" ]
then
    echo "OK: Not found any $levels in dmesg since $since_date"
    EXIT_CODE=$CODE_OK
else
    count=(${#output[@]})
    msg="Found $count msg since $since_date in dmesg"

    if [ $count -ge $crit ]
    then
      msg="CRITICAL: ${msg} (>$crit)"
      EXIT_CODE=$CODE_CRIT
    elif [ $count -ge $warn ]
    then
      msg="WARNING: ${msg} (>$warn)"
      EXIT_CODE=$CODE_WARN
    else
      msg="OK: ${msg} (<$warn)"
      EXIT_CODE=$CODE_OK
    fi

    for i in "${output[@]}"
    do
        msg="${msg}\n$i"
    done
fi

echo -e "${msg}"
exit $EXIT_CODE
