#!/usr/bin/env bash
#
# Nagios plugin for FTP/FTPS service health.
# Connects via curl, logs in (USER/PASS), forces passive mode (PASV) and lists a
# directory to verify the server actually serves a session end-to-end — not just
# that the control port is open. With --tls it upgrades to explicit FTPS
# (AUTH TLS) and requires the encrypted channel.
#
# Severity:
#   CRITICAL  connection refused/reset, timeout, login denied, TLS required but
#             unavailable, TLS handshake/cert failure, directory access denied
#   WARNING   (reserved — currently unused; listing succeeds or it fails hard)
#   OK        login + passive listing succeeded
#   UNKNOWN   DNS resolution failure, missing curl, bad arguments, unmapped error
#
# Perfdata: entries (files listed), time (total session time in seconds)
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $(basename "$0") -H <host> -u <user> [-P <password>] [options]

Options:
  -H, --host HOST          FTP host or IP (required)
  -p, --port PORT          Control port (default: 21)
  -u, --user USER          Login user (required)
  -P, --password PASS      Login password (falls back to env \$FTP_PASSWORD)
  -d, --dir PATH           Directory to list after login (default: /)
  -T, --tls                Require explicit FTPS (AUTH TLS) — fail if unavailable
  -k, --insecure           Skip TLS certificate verification (self-signed certs)
  -n, --nagios             Replace newlines with <br/> for Nagios web UI
  -t, --timeout SECONDS    Whole-session timeout in seconds (default: 10)
  -h, --help               Show this help

Environment variables:
  FTP_PASSWORD             Used when -P/--password is not provided

Examples:
  # Plain FTP login + list the root dir
  $(basename "$0") -H ftp.example.com -u monitor -P secret

  # Explicit FTPS with a self-signed cert, list a sub-directory
  $(basename "$0") -H ftp.example.com -u monitor -P secret -d uploads -T -k

  # Password from the environment, Nagios web-UI output
  FTP_PASSWORD=secret $(basename "$0") -H ftp.example.com -u monitor -n

Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
EOF
}

HOST=""
PORT=21
USER_NAME=""
PASSWORD=""
DIR="/"
USE_TLS=0
INSECURE=0
NAGIOS_MODE=0
TIMEOUT=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--host)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            HOST="$2"; shift 2 ;;
        -p|--port)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PORT="$2"; shift 2 ;;
        -u|--user)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            USER_NAME="$2"; shift 2 ;;
        -P|--password)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            PASSWORD="$2"; shift 2 ;;
        -d|--dir)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            DIR="$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
            TIMEOUT="$2"; shift 2 ;;
        -T|--tls)
            USE_TLS=1; shift ;;
        -k|--insecure)
            INSECURE=1; shift ;;
        -n|--nagios)
            NAGIOS_MODE=1; shift ;;
        -h|--help)
            usage; exit "$EXIT_OK" ;;
        *)
            echo "UNKNOWN: Unknown argument: $1" >&2
            usage >&2
            exit "$EXIT_UNKNOWN" ;;
    esac
done

print_msg() {
    local msg="$1"
    if [[ "$NAGIOS_MODE" -eq 1 ]]; then
        printf '%s\n' "${msg//$'\n'/<br/>}"
    else
        printf '%s\n' "$msg"
    fi
}

PASSWORD="${PASSWORD:-${FTP_PASSWORD:-}}"

if [[ -z "$HOST" ]]; then
    print_msg "UNKNOWN: host not provided (use -H/--host)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$USER_NAME" ]]; then
    print_msg "UNKNOWN: user not provided (use -u/--user)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$PASSWORD" ]]; then
    print_msg "UNKNOWN: password not provided (use -P/--password or set FTP_PASSWORD env var)"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]] || (( PORT > 65535 )); then
    print_msg "UNKNOWN: --port must be 1-65535, got: '$PORT'"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi

if ! command -v curl >/dev/null 2>&1; then
    print_msg "UNKNOWN: Required tool not found: curl"
    exit "$EXIT_UNKNOWN"
fi

# Normalize the directory into a trailing-slash path so curl performs a listing
# (NLST) rather than trying to RETR a file. Strip surrounding slashes, then
# re-add exactly one trailing slash.
dir_path="${DIR#/}"
dir_path="${dir_path%/}"

body_file=$(mktemp)
err_file=$(mktemp)
trap 'rm -f "$body_file" "$err_file"' EXIT

curl_args=(
    -sS
    -m "$TIMEOUT"
    --ftp-pasv
    -l
    -o "$body_file"
    -w '%{time_total}'
    -u "${USER_NAME}:${PASSWORD}"
)
# Explicit FTPS: keep the ftp:// scheme but require an AUTH TLS upgrade.
[[ "$USE_TLS" -eq 1 ]] && curl_args+=(--ssl-reqd)
[[ "$INSECURE" -eq 1 ]] && curl_args+=(-k)

url="ftp://${HOST}:${PORT}/${dir_path}${dir_path:+/}"

time_total=$(curl "${curl_args[@]}" "$url" 2>"$err_file")
rc=$?

mode="FTP"
[[ "$USE_TLS" -eq 1 ]] && mode="FTPS"

# Trim curl's stderr to a single tidy line for the plugin output.
curl_err=$(tr '\n' ' ' < "$err_file" | sed 's/curl: ([0-9]*) //; s/[[:space:]]*$//')

if [[ "$rc" -eq 0 ]]; then
    entries=$(grep -c . "$body_file" 2>/dev/null || echo 0)
    listed_dir="/${dir_path}"
    perf="entries=${entries};;;0 time=${time_total}s"
    print_msg "OK: ${mode} login OK on ${HOST}:${PORT}, listed ${listed_dir} (${entries} entries) | ${perf}"
    exit "$EXIT_OK"
fi

# Map curl exit codes to Nagios severity.
#   service-down / auth / TLS problems  -> CRITICAL
#   DNS / unmapped                      -> UNKNOWN
case "$rc" in
    6)
        print_msg "UNKNOWN: Could not resolve host ${HOST}${curl_err:+ — $curl_err}"
        exit "$EXIT_UNKNOWN" ;;
    7)
        print_msg "CRITICAL: Could not connect to ${HOST}:${PORT}${curl_err:+ — $curl_err}"
        exit "$EXIT_CRITICAL" ;;
    28)
        # curl maps a control-channel 421 ("service not available" — e.g.
        # Pure-FTPd refusing cleartext: "reconnect using TLS security
        # mechanisms") to exit 28, the same code as a genuine network timeout.
        # Tell them apart by elapsed time: a real timeout burns ~$TIMEOUT
        # seconds, an immediate 421 returns in a fraction of one.
        if awk "BEGIN{exit !(${time_total:-0} < ${TIMEOUT}/2)}" 2>/dev/null; then
            print_msg "CRITICAL: ${mode} session to ${HOST}:${PORT} rejected immediately (curl 28 after ${time_total:-0}s — not a real timeout); server likely refuses cleartext FTP — retry with -T/--tls${curl_err:+ — $curl_err}"
        else
            print_msg "CRITICAL: Timeout after ${TIMEOUT}s connecting to ${HOST}:${PORT}${curl_err:+ — $curl_err}"
        fi
        exit "$EXIT_CRITICAL" ;;
    67)
        print_msg "CRITICAL: ${mode} login denied for user '${USER_NAME}' on ${HOST}:${PORT}${curl_err:+ — $curl_err}"
        exit "$EXIT_CRITICAL" ;;
    9)
        print_msg "CRITICAL: Access denied to directory '/${dir_path}' on ${HOST}:${PORT}${curl_err:+ — $curl_err}"
        exit "$EXIT_CRITICAL" ;;
    35|58|59|60|64|66|77|82|83)
        print_msg "CRITICAL: TLS error talking to ${HOST}:${PORT}${curl_err:+ — $curl_err}"
        exit "$EXIT_CRITICAL" ;;
    *)
        print_msg "UNKNOWN: ${mode} check failed (curl exit ${rc})${curl_err:+ — $curl_err}"
        exit "$EXIT_UNKNOWN" ;;
esac
