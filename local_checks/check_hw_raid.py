#!/usr/bin/env python3

import sys
import json
import shlex
import subprocess
import argparse

STORCLI_CMD="/usr/local/bin/storcli64"
EXIT_CODE=0

def get_data(cmd):
    return json.loads(run_cmd(cmd))["Controllers"][0]["Response Data"]

def run_cmd(cmd, check=True) -> str:
    process = subprocess.run(shlex.split(cmd), stdin=subprocess.DEVNULL, stderr=subprocess.PIPE, stdout=subprocess.PIPE, check=check, text=True)
    return process.stdout or process.stderr

def parse_args():
    parser = argparse.ArgumentParser(description='Check hardware RAID via storcli', add_help=False)
    parser.add_argument('-c', '--controller', default=0, required=False, type=int)
    parser.add_argument('-d', '--delimiter', default="\n")
    return parser.parse_args()

if __name__ == "__main__":
    args = parse_args()
    exit_code = 0
    try:
        raid_status = get_data(f"{STORCLI_CMD} /c{args.controller}/vall show J")
        disk_status = get_data(f"{STORCLI_CMD} /c{args.controller}/eall/sall show J")
    except Exception as e:
        print(f"ERROR: Cannot retrieve data using {STORCLI_CMD}: {e}")
        sys.exit(2)
    msg = ""
        
    for raid in raid_status["Virtual Drives"]:
        state = raid['State']
        consist = raid['Consist']
        access = raid['Access']
        if 'Optl' not in state or 'Yes' not in consist or 'RW' not in access: 
            exit_code = 2
            msg += "CRITICAL: "
        else:
            msg += "OK: "
        msg += f"{raid['Name']} ({raid['TYPE']}) state={state} consist={consist} access={access}{args.delimiter}"
    
    for index, disk in enumerate(disk_status["Drive Information"]):
        state = disk['State']
        if 'Onln' not in state:
            exit_code = 2
            msg += "CRITICAL: "
        else:
            msg += "OK: "
        msg += f"DISK{index} {disk['Med']}{disk['EID:Slt']} ({disk['Size']}) state={state}{args.delimiter}"

    print(msg[:-(len(args.delimiter))])
    sys.exit(exit_code)
