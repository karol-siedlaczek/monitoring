#!/bin/bash

echo "show stat" | socat unix-connect:/var/run/haproxy/admin.sock stdio | cut -d "," -f 1,2,18 | tr "\n" ";"
