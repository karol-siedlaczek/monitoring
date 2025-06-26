#!/usr/bin/env python3

from sys import exit
import json
import argparse
from requests import get, Session
from requests.exceptions import ConnectionError, ConnectTimeout

class Nagios():
    OK = 0
    WARNING = 1
    CRITICAL = 2
    UNKNOWN = 3

def send_req(session, url):
    try:
        response = session.get(url, timeout=5)

        if response.ok:
            return response
        else:
            print(f"ERROR: Request to {url} returned {response.status_code} code")
            exit(Nagios.CRITICAL)
    except (ConnectTimeout, ConnectionError) as e:
        print(f"ERROR: Connection error to {url}")
        exit(Nagios.CRITICAL)


def parse_args():
    parser = argparse.ArgumentParser(description='Check prometheus instance health')
    parser.add_argument('-H', '--host', required=True, help='Prometheus host')
    parser.add_argument('-u', '--user', required=True, help='Username for basic authentication')
    parser.add_argument('-p', '--password', required=True, help='Password for basic authentication')
    parser.add_argument('-e', '--excludedTargets', nargs="+", required=False, default=[], help='Following targets will not be checked')
    parser.add_argument('-n', '--nagiosOutput', action='store_true', default=False, help='Set to nagios line separator </br>')
    parser.add_argument('-v', '--verbose', action='store_true', default=False, help='Show all target status')
    return parser.parse_args()

if __name__ == "__main__":
    args = parse_args()
    exit_code = Nagios.OK
    
    session = Session()
    session.auth = (args.user, args.password)
    
    health = send_req(session, f"https://{args.host}/-/healthy").text.strip()

    # String 'Prometheus Server' is in older versions of prometheus
    if health.lower() != 'prometheus server is healthy.' and health.lower() != 'prometheus is healthy.':
        print(f"ERROR: Health check failed: {health}")
    
    response = send_req(session, f'https://{args.host}/api/v1/targets')
    output = json.loads(response.text)
    line_separator = '</br>' if args.nagiosOutput else '\n'

    if output.get('status') != 'success':
        print(f"ERROR: Status is {output.get('status')}")
        exit(Nagios.CRITICAL)
    else:
        data = output.get('data')
        active_targets = data.get('activeTargets')
        msg = ''
        if data and active_targets:
            for active_target in active_targets:
                labels = active_target.get('labels')
                instance = labels.get('instance')
              
                if (instance in args.excludedTargets):
                    if (args.verbose):
                        print(f'Target {active_target} excluded from checking')
                    continue

                job = labels.get('job')
                health = active_target.get('health')
                
                if health.lower() != 'up':
                    msg += f'{health.upper()}: {instance}/{job} - {active_target.get("lastError")}{line_separator}'
                    exit_code = Nagios.CRITICAL
                elif args.verbose:
                    msg += f'{health.upper()}: {instance}/{job}{line_separator}'
            
            if exit_code == Nagios.OK:
                print("OK: All targets are up and service is healthy")
            else:
                print(msg[:-5] if args.nagiosOutput else msg[:-1])
            exit(exit_code)
        else:
            print("ERROR: No data returned")
            exit(Nagios.CRITICAL)
        
    
