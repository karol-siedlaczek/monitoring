#!/bin/bash

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

help() {
  echo "Usage: $0 -H <HOST> "
  echo "  -H                        Hostname or IP address of the target machine"
  exit 1
}

while getopts ":H:" opt; do
  case $opt in
    H) HOST=$OPTARG ;;
    \?) help ;;
  esac
done

if [ -z "$HOST" ]; then
  help
fi

VALUE=$(curl $HOST:8086/health | jq '.status')
output_exit_code=$?
if [ $output_exit_code -gt 0 ]
then
  echo "ERROR: No response from remote host $HOST, exit code is $output_exit_code"
  exit $EXIT_CODE
fi

if [[ "$VALUE" == *"pass"* ]]; then
  echo "OK: Health check passed"
  exit $NAGIOS_OK
else
  echo "CRITICAL: health check not passed"
  exit $NAGIOS_CRIT
fi
