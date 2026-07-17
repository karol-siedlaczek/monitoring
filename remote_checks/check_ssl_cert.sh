#!/bin/bash
## Author: Sharad Kumar Chhetri
## Creation Date : 10-Dec-2014
## Description : Send Warning/Critical alert before expiry date of SSL Certificate.
## Version : 1.0
##
## Usage example: /check_ssl_cert_expiry -h www.google.co.in -w 90 -c 60
## -w = integer number (Warning days)
## -c = integer number (Critical days)
#
# Requirement : bc command should be available in system.
#

_HOST=""
_WARNEXPIRYDAYS=""
_CRITEXPIRYDAYS=""
_PORT=""

while getopts "h:w:c:p:" opt
    do
    case $opt in
        h ) _HOST=$OPTARG;;
        w ) _WARNEXPIRYDAYS=$OPTARG;;
        c ) _CRITEXPIRYDAYS=$OPTARG;;
        p ) _PORT=$OPTARG;;
    esac
done

# Port is optional; default to 443 so existing (HTTPS) callers keep working.
_PORT=${_PORT:-443}

if [ ! "$_HOST" ]
    then
    printf "UNKNOWN: Either give Hostname in syntax as www.example.com or example.com with -h!\n"
    exit 3
fi
if [ ! "$_WARNEXPIRYDAYS" ]
    then
    printf "UNKNOWN: Add WARNING expiry in days with -w\n"
    exit 3
fi
if [ ! "$_CRITEXPIRYDAYS" ]
    then
    printf "UNKNOWN: Add CRITICAL expiry in days with -c\n"
    exit 3
fi

EXPIRYDATE=`echo "QUIT" | timeout 10 openssl s_client -connect $_HOST:$_PORT -servername $_HOST 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null|sed 's/notAfter=//g'`
#echo $EXPIRYDATE

if [ ! "$EXPIRYDATE" ]
    then
    echo "UNKNOWN: could not retrieve certificate from $_HOST:$_PORT"
    exit 3
fi

EXPIRYDATE_epoch=$(date --date "$EXPIRYDATE" +%s)
CURRENT_DATE_epoch=`date +%s`

### Expiry date as ISO (YYYY-MM-DD) for the message
EXPIRY_ISO=`date --date "@$EXPIRYDATE_epoch" +%Y-%m-%d`

epochDiff=`echo "$EXPIRYDATE_epoch" - "$CURRENT_DATE_epoch"|bc`

### Get difference of days
dayDiff=`echo "$epochDiff"/86400|bc`

if [ "$dayDiff" -le "$_CRITEXPIRYDAYS" ]
then
    echo "CRITICAL: $_HOST:$_PORT certificate expires $EXPIRY_ISO (in $dayDiff days)"
    exit 2
else
    if [  "$dayDiff" -le "$_WARNEXPIRYDAYS" ]
    then
        echo "WARNING: $_HOST:$_PORT certificate expires $EXPIRY_ISO (in $dayDiff days)"
        exit 1
    else
        echo "OK: $_HOST:$_PORT certificate expires $EXPIRY_ISO (in $dayDiff days)"
        exit 0
    fi
fi
