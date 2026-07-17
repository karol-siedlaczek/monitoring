#!/bin/bash

# Checks if partition is mounted by uuid

# Nagios exit codes
OK=0
WARN=1
CRITICAL=2
UNKNOWN=3

exit_code=$OK

for uuid in "$@"
do
  mountpoint=$(lsblk -o MOUNTPOINT "/dev/disk/by-uuid/$uuid" | awk 'NR==2')
  name=$(lsblk -o NAME "/dev/disk/by-uuid/$uuid" | awk 'NR==2')
  if [ -z $name ] # Partition not found
  then
    output="${output}UNKNOWN: $uuid not a block device\n"
    if [ $exit_code != $CRITICAL ]
    then
      exit_code=$UNKNOWN
    fi
  elif [[ -n $mountpoint ]] # Partition is mounted
  then
    output="${output}OK: /dev/$name mounted in $mountpoint\n"
  else  # Partition is not mounted
    output="${output}CRITICAL: /dev/$name not mounted\n"
    exit_code=$CRITICAL
  fi
done

echo ${output%??}
exit $exit_code
