#!/bin/bash

MNGMT_STATION=$1 # address
COMMUNITY_STRING=$2 # public
HOST_NAME=$3 # string
HOST_STAT_ID=$4 # integer
HOST_OUTPUT=$5 # string
HOST_LAST_CHANGE=$6 # integer
HOST_LAST_CHECK=$7 # integer
HOST_DURATION_SEC=$8 # integer
HOST_ATTEMPT=$9 # integer
HOST_GROUPNAME=${10} # string
HOST_STATE_TYPE=${11}  # string

if [[ -z "$MNGMT_STATION" || -z "$COMMUNITY_STRING" || -z "$HOST_NAME" || -z "$HOST_STAT_ID" || -z "$HOST_OUTPUT" || -z "$HOST_LAST_CHANGE" || -z "$HOST_LAST_CHECK" || -z "$HOST_DURATION_SEC" || -z "$HOST_ATTEMPT" || -z "$HOST_GROUPNAME" || -z "$HOST_STATE_TYPE" ]]
then
   echo -e "Syntax error\nUsage: $0 <MNGMT_STATION> <COMMUNITY_STRING> <HOST_NAME> <HOST_STAT_ID> <HOST_OUTPUT> <HOST_LAST_CHANGE> <HOST_LAST_CHECK> <HOST_DURATION_SEC> <HOST_ATTEMPT> <HOST_GROUPNAME> <HOST_STATE_TYPE>"
   exit 0
fi

/usr/bin/snmptrap -v 2c -c $COMMUNITY_STRING $MNGMT_STATION '' NAGIOS-NOTIFY-MIB::nHostEvent nHostname s "$HOST_NAME" nHostStateID i $HOST_STAT_ID nHostOutput s "$HOST_OUTPUT" nHostLastChange i $HOST_LAST_CHANGE nHostLastCheck i $HOST_LAST_CHECK nHostDurationSec i $HOST_DURATION_SEC nHostAttempt i $HOST_ATTEMPT nHostGroupName s "$HOST_GROUPNAME" nHostStateType s "$HOST_STATE_TYPE"