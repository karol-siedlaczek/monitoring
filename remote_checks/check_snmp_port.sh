#!/bin/bash

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
SNMP_PORT="161"
AUTH_PROTOCOL="SHA"
PRIV_PROTOCOL="AES"

help() {
  echo "Usage: $0 -H <HOST> -I <INTERFACE_IP> -P <PORT> -X <SNMP_PASSWORD>"
  echo "  -H                        Hostname or IP address of the target machine"
  echo "  -l                        SNMPv3 authentication user"
  echo "  -X                        SNMP v3 authentication passphrase and encryption passphrase"
  echo "  -p=SNMP_PORT              SNMP port, default is $SNMP_PORT"
  echo "  -a=AUTH_PROTOCOL          Authentication protocol, default is (MD5|SHA, default: $AUTH_PROTOCOL)"
  echo "  -x=PRIV_PROTOCOL          Priv protocol, default is (AES|DES, default: $PRIV_PROTOCOL)"
  echo "  -I                        Interface IP on target machine"
  echo "  -P                        Port number on target machine"
  exit 1
}

while getopts "H:I:P:X:l:" opt; do
  case $opt in
    H) HOST=$OPTARG ;;
    l) SNMP_USER=$OPTARG ;;
    I) INTERFACE_IP=$OPTARG ;;
    P) PORT=$OPTARG ;;
    X) SNMP_PASSWORD=$OPTARG ;;
    \?) help ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$INTERFACE_IP" ] || [ -z "$PORT" ] || [ -z "$SNMP_PASSWORD" ] || [ -z "$SNMP_USER" ]; then
  help
fi

OID="1.3.6.1.2.1.6.13.1.1.$INTERFACE_IP.$PORT"
VALUE=$(snmpwalk -O qv -v 3 -l authPriv -u $SNMP_USER -a $AUTH_PROTOCOL -x $PRIV_PROTOCOL -A $SNMP_PASSWORD -X $SNMP_PASSWORD $HOST:$SNMP_PORT $OID)
output_exit_code=$?

if [ $output_exit_code -gt 0 ]
then
  echo "ERROR: no response from remote host $HOST, exit code is $output_exit_code"
  exit $EXIT_CODE
fi

if [[ "$VALUE" == *"listen"* ]]; then
  echo "OK - Service is listening on $INTERFACE_IP:$PORT"
  exit $NAGIOS_OK
else
  echo "CRITICAL - Service is not listening on $INTERFACE_IP:$PORT"
  exit $NAGIOS_CRIT
fi
