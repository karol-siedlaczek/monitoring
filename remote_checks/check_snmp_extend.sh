#!/bin/bash

set -ueo pipefail

PATH=/bin:/usr/bin

HOST=${1:-}
USER=${2:-}
PASS=${3:-}
EXT=${4:-}

if [[ -z "$HOST" || -z "$USER" || -z "$PASS" || -z "$EXT" ]]
then
   echo "Usage: $0 <host> <user> <password> <extension>" >&2
   exit 3
fi

SNMP_COMMON="snmpwalk -v 3 -u $USER -A $PASS -X $PASS -a SHA -x AES -l authPriv -Ov -Oq $HOST"

EXIT_CODE=$($SNMP_COMMON NET-SNMP-EXTEND-MIB::nsExtendResult.\"$EXT\")
$SNMP_COMMON NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"$EXT\"

exit $EXIT_CODE