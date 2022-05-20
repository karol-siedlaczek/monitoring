#!/bin/bash

# For output
/usr/bin/snmpget -t 10 -OQv -l authPriv -u <snmp_user> -A <snmp_pass> -X <snmp_pass> <snmp_host>:<snmp_port> NET-SNMP-EXTEND-MIB::nsExtendOutputFull.\"<extend_check_name>\"

# For exit code
/usr/bin/snmpget -t 10 -OQv -l authPriv -u <snmp_user> -A <snmp_pass> -X <snmp_pass> <snmp_host>:<snmp_port> NET-SNMP-EXTEND-MIB::nsExtendResult.\"<extend_check_name>\"
