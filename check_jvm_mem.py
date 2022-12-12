#!/usr/bin/env python3

import os
import requests
import argparse
import logging
import logging.config
import sys
import time
from pathlib import Path
from requests.exceptions import InvalidURL
from urllib3.exceptions import ReadTimeoutError, LocationParseError
from requests.exceptions import ConnectTimeout, ConnectionError, ReadTimeout
from requests.auth import HTTPBasicAuth

NAGIOS_OK = 0
NAGIOS_WARNING = 1
NAGIOS_CRITICAL = 2
NAGIOS_UNKNOWN = 3
TIMEOUT = 5
NON_HEAP_MEM = 'non-heap'
HEAP_MEM = 'heap'
TMP_FILE = '/tmp/check_jvm_memory.tmp'
LOG_FILE = os.path.abspath(os.path.join(os.sep, 'var', 'log', f'{os.path.basename(__file__).split(".")[0]}.log'))
PORT_MAP = {
    8787: 'jira',
    8888: 'confluence'
}

logging.basicConfig(filename=LOG_FILE, format='%(asctime)s | %(name)s | %(levelname)s | %(message)s', datefmt='%Y-%m-%d %H:%M:%S', level=logging.DEBUG)


def check_jvm_memory(host_address, port, user, passwd, warning, critical, mem_type, run_gc, delay, timeout):
    state = NAGIOS_UNKNOWN
    url = f'{get_base_url(host_address, port)}/java.lang:type=Memory'
    try:
        response = requests.get(url, auth=HTTPBasicAuth(user, passwd), timeout=timeout)
    except (ConnectTimeout, TimeoutError):
        print(f'CRITICAL - Connection timeout to {url}')
        sys.exit(NAGIOS_CRITICAL)
    except (ReadTimeoutError, ReadTimeout):
        print(f'CRITICAL - Connection timeout to {url} in {timeout} seconds')
        sys.exit(NAGIOS_CRITICAL)
    except ConnectionError:
        print(f'CRITICAL - Connection error to {url}')
        sys.exit(NAGIOS_CRITICAL)
    except (LocationParseError, InvalidURL) as e:
        print(f'CRITICAL - {e}')
        sys.exit(NAGIOS_CRITICAL)
    if not response.ok:
        print(f'UNKNOWN - HTTP code status is {response.status_code} on {url}')
        sys.exit(NAGIOS_UNKNOWN)
    response = response.json()
    if mem_type == HEAP_MEM:
        heap_max = response['value']['HeapMemoryUsage']['max']
        heap_used = round(response['value']['HeapMemoryUsage']['used'] / heap_max*100, 2)
        heap_allocated = round(response['value']['HeapMemoryUsage']['committed'] / heap_max*100, 2)
        heap_free = round(100 - heap_allocated, 2)
        state = get_mem_state(heap_used, warning, critical)
        print(f"Used: {heap_used}%\nAllocated: {heap_allocated}%\nFree: {heap_free}%")
    elif mem_type == NON_HEAP_MEM:
        non_heap_used = round(response['value']['NonHeapMemoryUsage']['used'] / 1024 / 1024 / 1024, 2)
        non_heap_allocated = round(response['value']['NonHeapMemoryUsage']['committed'] / 1024 / 1024 / 1024, 2)
        non_heap_init = round(response['value']['NonHeapMemoryUsage']['init'] / 1024 / 1024 / 1024, 2)
        state = get_mem_state(non_heap_allocated, warning, critical)
        if state == NAGIOS_WARNING:
            print(f'WARNING - Allocated value reached {warning} GB')
        elif state == NAGIOS_CRITICAL:
            print(f'CRITICAL - Allocated value reached {critical} GB')
        print(f"Used: {non_heap_used} GB\nAllocated: {non_heap_allocated} GB\nInit: {non_heap_init} GB")
    if state == NAGIOS_CRITICAL and run_gc:
        run_garbage_collector(port, delay)
    sys.exit(state)


def get_mem_state(mem_used, warn_threshold, crit_threshold):
    if mem_used > crit_threshold:
        logging.warning(f'state is CRITICAL: {mem_used} > {crit_threshold}')
        return NAGIOS_CRITICAL
    elif mem_used > warn_threshold:
        logging.warning(f'state is WARNING: {mem_used} > {warn_threshold}')
        return NAGIOS_WARNING
    else:
        return NAGIOS_OK


def get_base_url(host_address, port):
    return f'http://{host_address}:{port}/jolokia/read'


def run_garbage_collector(port, delay):
    if os.path.isfile(TMP_FILE):
        with open(TMP_FILE, 'r') as f:
            last_timestamp = float(f.read())  # read last timestamp from file
        if time.time() - last_timestamp <= delay*60:  # check if delay passed before run gc collector
            logging.info(f'garbage collector not executed, because {delay} minutes not passed since last execution')
            return
    try:
        pid = os.popen(f'cat /opt/{PORT_MAP[port]}/work/catalina.pid').read().strip()
    except KeyError:
        logging.warning(f'garbage collector not executed, because port {port} is not related with values in PORT_MAP')
        return
    command = f'su {PORT_MAP[port]} -c "jcmd {pid} GC.run"'
    os.system(command)
    with open(TMP_FILE, 'w') as file:
        file.write(str(time.time()))
    logging.info(f'garbage collector executed by command "{command}"')


def parse_args():
    arg_parser = argparse.ArgumentParser()
    arg_parser.add_argument('-H', '--hostAddress', type=str, required=True)
    arg_parser.add_argument('-u', '--user', type=str, required=True)
    arg_parser.add_argument('-p', '--passwd', type=str, required=True)
    arg_parser.add_argument('-w', '--warning', type=float, default=75)
    arg_parser.add_argument('-c', '--critical', type=float, default=90)
    arg_parser.add_argument('-P', '--port', type=int, required=True)
    arg_parser.add_argument('-t', '--type', choices=['heap', 'non-heap'], required=True)
    arg_parser.add_argument('-T', '--timeout', help=f'timeout in seconds, default is {TIMEOUT}', type=int, default=TIMEOUT, required=False)
    arg_parser.add_argument('--runGC', help='if value reach critical threshold script run garbage collector', action='store_true')
    arg_parser.add_argument('-d', '--delay', help='delay in minutes for garbage collector runs, only usable with --runGC arg', type=float, default=2)
    return arg_parser.parse_args()


if __name__ == '__main__':
    args = parse_args()
    check_jvm_memory(args.hostAddress, args.port, args.user, args.passwd, args.warning, args.critical, args.type, args.runGC, args.delay, args.timeout)
