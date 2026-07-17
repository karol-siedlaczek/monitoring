#!/bin/bash

NAGIOS_OK=0
NAGIOS_WARN=1
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN

TIMEOUT=5

OPTS=$(getopt -o i:p:t:h --long ip:,port:,timeout:,help -- "$@")

eval set -- "$OPTS"

while true; do
  case "$1" in
    -i|--ip) IP=$2; shift 2;;
    -p|--port) PORT=$2; shift 2;;
    -t|--timeout) TIMEOUT=$2; shift 2;;
    -h|--help)
      echo "Usage: $0 -i <ip> -p <port> [-t <timeout>]"
      exit $NAGIOS_UNKNOWN;;
    --) shift; break;;
    *) echo "ERROR: Invalid option: $1"; exit $NAGIOS_UNKNOWN;;
  esac
done

if [ -z "$IP" ]; then
  echo "ERROR: IP address required (-i)"
  exit $NAGIOS_UNKNOWN
fi

if [ -z "$PORT" ]; then
  echo "ERROR: Port required (-p)"
  exit $NAGIOS_UNKNOWN
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: Invalid port: ${PORT}"
  exit $NAGIOS_UNKNOWN
fi

if timeout "$TIMEOUT" bash -c "echo > /dev/tcp/${IP}/${PORT}" 2>/dev/null; then
  echo "OK: TCP connection to ${IP}:${PORT} succeeded"
  EXIT_CODE=$NAGIOS_OK
else
  echo "CRITICAL: TCP connection to ${IP}:${PORT} failed"
  EXIT_CODE=$NAGIOS_CRIT
fi

exit $EXIT_CODE
