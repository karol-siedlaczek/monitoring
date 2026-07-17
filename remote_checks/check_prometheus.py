#!/usr/bin/env python3

from sys import exit
import json
import argparse
from requests import Session
from requests.exceptions import ConnectionError, ConnectTimeout

class Nagios():
    OK = 0
    WARNING = 1
    CRITICAL = 2
    UNKNOWN = 3

def send_req(session, url, timeout):
    try:
        response = session.get(url, timeout=timeout)
    except (ConnectTimeout, ConnectionError):
        print(f"UNKNOWN: Connection error to {url}")
        exit(Nagios.UNKNOWN)

    if response.ok:
        return response
    if 500 <= response.status_code < 600:
        print(f"UNKNOWN: Request to {url} returned {response.status_code} code")
        exit(Nagios.UNKNOWN)
    print(f"CRITICAL: Request to {url} returned {response.status_code} code")
    exit(Nagios.CRITICAL)


def parse_args():
    parser = argparse.ArgumentParser(description='Check prometheus/vmagent instance health')
    parser.add_argument('-u', '--url', required=True, help='Prometheus/vmagent base URL (include scheme, e.g. https://victoria.example.com)')
    parser.add_argument('-U', '--user', required=False, default=None, help='Username for basic authentication')
    parser.add_argument('-P', '--password', required=False, default=None, help='Password for basic authentication')
    parser.add_argument('--path-prefix', default='', help='URL path prefix (e.g. /vmagent when proxied under a subpath)')
    parser.add_argument('-e', '--excluded-instances', nargs="+", required=False, default=[], help='Targets with these instance labels will not be checked')
    parser.add_argument('-j', '--excluded-jobs', nargs="+", required=False, default=[], help='Targets with these job labels will not be checked')
    parser.add_argument('-n', '--nagios', action='store_true', default=False, help='Replace newlines with <br/> for Nagios web UI')
    parser.add_argument('-t', '--timeout', type=int, default=10, help='HTTP timeout in seconds (default: 10)')
    parser.add_argument('-v', '--verbose', action='store_true', default=False, help='Show all target status')
    return parser.parse_args()

# Accepted bodies on /-/healthy. Lowercased and trimmed before comparison.
HEALTHY_RESPONSES = {
    'prometheus server is healthy.',  # prometheus, older versions
    'prometheus is healthy.',         # prometheus, newer versions
    'ok',                             # vmagent / VictoriaMetrics components
    'victoriametrics is healthy.',    # victoria metrics
}

if __name__ == "__main__":
    args = parse_args()
    exit_code = Nagios.OK

    session = Session()
    if args.user and args.password:
        session.auth = (args.user, args.password)

    base = f"{args.url.rstrip('/')}{args.path_prefix}"
    line_separator = '<br/>' if args.nagios else '\n'

    health = send_req(session, f"{base}/-/healthy", args.timeout).text.strip()

    if health.lower() not in HEALTHY_RESPONSES:
        print(f"CRITICAL: Health check failed: {health}")
        exit(Nagios.CRITICAL)

    response = send_req(session, f'{base}/api/v1/targets', args.timeout)
    output = json.loads(response.text)

    if output.get('status') != 'success':
        print(f"UNKNOWN: API returned status {output.get('status')}")
        exit(Nagios.UNKNOWN)

    data = output.get('data')
    active_targets = data.get('activeTargets') if data else None
    if not active_targets:
        print("UNKNOWN: No active targets returned by API")
        exit(Nagios.UNKNOWN)

    msg = ''
    for active_target in active_targets:
        labels = active_target.get('labels')
        instance = labels.get('instance')
        job = labels.get('job')

        if instance in args.excluded_instances:
            if args.verbose:
                msg += f'EXCLUDED: {instance} (instance){line_separator}'
            continue

        if job in args.excluded_jobs:
            if args.verbose:
                msg += f'EXCLUDED: {instance}/{job} (job){line_separator}'
            continue

        target_health = active_target.get('health', '').lower()
        last_error = active_target.get('lastError') or ''

        if target_health == 'up':
            if args.verbose:
                msg += f'OK: {instance}/{job}{line_separator}'
        elif last_error:
            msg += f'CRITICAL: {instance}/{job} - {last_error}{line_separator}'
            exit_code = Nagios.CRITICAL
        else:
            # health != "up" with empty lastError == transient / not-yet-scraped;
            # surface as WARNING so we don't page on a benign scrape-cycle gap.
            msg += f'WARNING: {instance}/{job} - state={target_health or "unknown"}, no lastError{line_separator}'
            if exit_code == Nagios.OK:
                exit_code = Nagios.WARNING

    if exit_code == Nagios.OK:
        print("OK: All targets are up and service is healthy")
        if args.verbose and msg:
            print(msg[:-len(line_separator)])
    else:
        print(msg[:-len(line_separator)])
    exit(exit_code)
        
    
