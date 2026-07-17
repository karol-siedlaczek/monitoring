#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

CHECK_ENABLED=false
CHECK_ACTIVE=false

OPTS=$(getopt -o s:h --long service:,check-enabled,check-active -- "$@")

eval set -- "$OPTS"

while true; do
  case "$1" in
    -s|--service) SERVICE_NAME=$2; shift 2;;
    --check-enabled) CHECK_ENABLED=true; shift;;
    --check-active) CHECK_ACTIVE=true; shift;;
    --) shift; break;;
    *) echo "ERROR: Invalid option: $1"; exit $NAGIOS_UNKNOWN;;
  esac
done

if [ -z "$SERVICE_NAME" ]; then
	echo "ERROR: Service name required (-s)"
	exit $NAGIOS_UNKNOWN
fi

if ! $CHECK_ENABLED && ! $CHECK_ACTIVE; then
	echo "ERROR: Need to specify at least one check: --check-enabled or --check-active"
	exit $NAGIOS_UNKNOWN
fi

msg=""

if $CHECK_ENABLED; then
	enabled_output=$(systemctl is-enabled "$SERVICE_NAME" 2>&1)

	if [[ "$enabled_output" == "enabled" ]] ; then
		msg+="is-enabled=OK "
		EXIT_CODE=$NAGIOS_OK
	else
		msg+="is-enabled=${enabled_output} "
		EXIT_CODE=$NAGIOS_CRIT
	fi
fi

if $CHECK_ACTIVE; then
	active_output=$(systemctl is-active "$SERVICE_NAME" 2>&1)

	if [[ "$active_output" == "active" ]]; then
		msg+="is-active=OK "
		if [[ $EXIT_CODE != $NAGIOS_CRIT ]]; then EXIT_CODE=$NAGIOS_OK; fi
	else
		msg+="active=${active_output} "
		EXIT_CODE=$NAGIOS_CRIT
	fi
fi

case $EXIT_CODE in
	0) state="OK" ;;
	1) state="WARNING" ;;
	2) state="CRITICAL" ;;
	*) state="UNKNOWN" ;;
esac

echo "$state: ${SERVICE_NAME} ${msg}"
exit $EXIT_CODE
