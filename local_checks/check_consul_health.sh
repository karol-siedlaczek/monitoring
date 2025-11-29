#!/bin/bash

# Karol Siedlaczek 2025

NAGIOS_OK=0
NAGIOS_CRIT=2
NAGIOS_UNKNOWN=3
EXIT_CODE=$NAGIOS_UNKNOWN
NAGIOS_ESCAPE=false
LINE_SEPARATOR="\n"
SERVICE="consul"
MSG=""

while getopts t:s:N flag; do
  case "${flag}" in
    t) TOKEN=${OPTARG};;
    s) SERVICE=${OPTARG};;
    N) NAGIOS_ESCAPE=true;;
  esac
done

if [[ -z "$TOKEN" ]]; then
    echo "Usage: $0 -t <CONSUL_HTTP_TOKEN>"
    exit $NAGIOS_UNKNOWN
fi

curl_output=$(curl -s --connect-timeout 10 --noproxy '*' --header "X-Consul-Token: $TOKEN" --fail --show-error http://10.33.17.111/v1/health/service/$SERVICE 2>&1)
curl_exit_code=$?

if [ $curl_exit_code -gt 0 ]; then
   echo "ERROR: ${curl_output}"
   exit $NAGIOS_CRIT
fi

if [[ $NAGIOS_ESCAPE = true ]]; then LINE_SEPARATOR="</br>"; fi

health_check_results=$(echo $curl_output | jq -r '[.[].Checks[] | select(.CheckID=="serfHealth") | {node: .Node, status: .Status, output: .Output}]')

if [[ -z "$health_check_results" || "$health_check_results" == "[]" ]]; then
    echo "CRITICAL: Health check returned an empty response for service: $SERVICE"
    exit $NAGIOS_CRIT
fi

EXIT_CODE=$NAGIOS_OK

while IFS=$'\t' read -r node status output; do
    if [[ "$status" == "passing" ]]; then
        MSG+="OK: Node $node status is healthy: $output${LINE_SEPARATOR}"
    else
        MSG+="CRITICAL: Node $node is unhealthy, status: $status, output: $output${LINE_SEPARATOR}"
        EXIT_CODE=$NAGIOS_CRIT
    fi
done < <( jq -r '.[] | [.node, .status, .output] | @tsv' <<< "$health_check_results" )

if [[ $NAGIOS_ESCAPE = true ]]; then echo -e ${MSG%?????}; else echo -e ${MSG%??}; fi
exit $EXIT_CODE
