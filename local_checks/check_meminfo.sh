#!/bin/bash

set -ueo pipefail

MEM_TOTAL=0
MEM_AV=0
SWAP_TOTAL=0
SWAP_AV=0

while read PARAM VALUE UNIT
do
    case $PARAM in
        'MemTotal:') MEM_TOTAL=$VALUE ;;
        'MemAvailable:') MEM_AV=$VALUE ;;
        'SwapTotal:') SWAP_TOTAL=$VALUE ;;
        'SwapFree:') SWAP_AV=$VALUE ;;
    esac
done < /proc/meminfo
SWAP=100

if [[ $SWAP_TOTAL -ne 0 ]]
then
    SWAP=$(($SWAP_AV*100/$SWAP_TOTAL))
fi

echo $(($MEM_AV*100/$MEM_TOTAL))/$SWAP
