#!/bin/bash

SOCKET=$1

if [[ -z "$SOCKET" ]]; then
   SOCKET="/var/run/haproxy/admin.sock"
fi

echo "show stat" | socat unix-connect:$SOCKET stdio | cut -d "," -f 1,2,18 | tr "\n" ";"

