#!/usr/bin/env bash
#
# Nagios plugin for OpenBao AppRole secret_id expiry.
# Authenticates via AppRole, iterates roles in the configured AppRole mount,
# looks up every secret_id accessor and reports those whose remaining TTL
# falls below the WARN/CRIT thresholds. The AppRole token created during
# the check is revoked at exit.
#
# Severity:
#   CRITICAL  any secret_id has remaining TTL < --critical days, OR any
#             secret_id never expires (suppress with --skip-no-expiry)
#   WARNING   any secret_id has remaining TTL < --warning days
#   OK        no secret_ids in the warning window and no non-expiring ones
#             (or those are suppressed)
#   UNKNOWN   network error, missing args, AppRole login failure, list failure
#
# Required policy capabilities (in addition to AppRole login + default).
# Replace 'approle' below if you use a custom mount via -A:
#   path "auth/approle/role"                              { capabilities = ["list"] }
#   path "auth/approle/role/+/secret-id"                  { capabilities = ["list", "sudo"] }
#   path "auth/approle/role/+/secret-id-accessor/lookup"  { capabilities = ["update"] }
#
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

set -u

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2
EXIT_UNKNOWN=3

usage() {
    cat <<EOF
Usage: $0 [options]

Thresholds:
  -w, --warning N          WARNING threshold in days            (default: $WARN_DAYS)
  -c, --critical N         CRITICAL threshold in days           (default: $CRIT_DAYS)

Connection:
  -u, --url URL            OpenBao address                      (fallbacks to env \$BAO_ADDR)
  -R, --role-id ID         AppRole role_id                      (fallbacks to env \$BAO_ROLE_ID)
  -S, --secret-id ID       AppRole secret_id                    (fallbacks to env \$BAO_SECRET_ID)
  -A, --auth-path PATH     AppRole mount path                   (default: $AUTH_PATH)
  -j, --jobs N             Parallel lookup jobs                 (default: $JOBS)
  -t, --timeout N          HTTP timeout in seconds              (default: $TIMEOUT)

Filtering (globs supported, repeatable):
  --include-role PATTERN   Include ONLY roles matching
  --exclude-role PATTERN   Exclude roles matching

Output:
  --skip-no-expiry         Suppress secret_ids that never expire (default: report as CRITICAL)
  -n, --nagios             Replace newlines with <br/> for Nagios web UI
EOF
}

URL=""
ROLE_ID=""
SECRET_ID=""
AUTH_PATH="approle"
WARN_DAYS="14"
CRIT_DAYS="7"
JOBS=5
SKIP_NO_EXPIRY=0
NAGIOS_MODE=0
TIMEOUT=10

INCLUDE_ROLES=()
EXCLUDE_ROLES=()

require_value() {
    [[ $# -lt 2 ]] && { echo "UNKNOWN: Missing value for $1" >&2; exit "$EXIT_UNKNOWN"; }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)            require_value "$@"; URL="$2"; shift 2 ;;
        -R|--role-id)        require_value "$@"; ROLE_ID="$2"; shift 2 ;;
        -S|--secret-id)      require_value "$@"; SECRET_ID="$2"; shift 2 ;;
        -A|--auth-path)      require_value "$@"; AUTH_PATH="$2"; shift 2 ;;
        -w|--warning)        require_value "$@"; WARN_DAYS="$2"; shift 2 ;;
        -c|--critical)       require_value "$@"; CRIT_DAYS="$2"; shift 2 ;;
        -j|--jobs)           require_value "$@"; JOBS="$2"; shift 2 ;;
        -t|--timeout)        require_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --include-role)      require_value "$@"; INCLUDE_ROLES+=("$2"); shift 2 ;;
        --exclude-role)      require_value "$@"; EXCLUDE_ROLES+=("$2"); shift 2 ;;
        --skip-no-expiry)    SKIP_NO_EXPIRY=1; shift ;;
        -n|--nagios)         NAGIOS_MODE=1; shift ;;
        -h|--help)           usage; exit "$EXIT_UNKNOWN" ;;
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

URL="${URL:-${BAO_ADDR:-}}"
ROLE_ID="${ROLE_ID:-${BAO_ROLE_ID:-}}"
SECRET_ID="${SECRET_ID:-${BAO_SECRET_ID:-}}"

if [[ -z "$URL" ]]; then
    print_msg "UNKNOWN: url not provided (use -u/--url or set BAO_ADDR env var)"
    exit "$EXIT_UNKNOWN"
fi

if [[ -z "$ROLE_ID" ]]; then
    print_msg "UNKNOWN: role_id not provided (use -R/--role-id or set BAO_ROLE_ID env var)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$SECRET_ID" ]]; then
    print_msg "UNKNOWN: secret_id not provided (use -S/--secret-id or set BAO_SECRET_ID env var)"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$WARN_DAYS" ]]; then
    print_msg "UNKNOWN: Missing required -w/--warning argument"
    exit "$EXIT_UNKNOWN"
fi
if [[ -z "$CRIT_DAYS" ]]; then
    print_msg "UNKNOWN: Missing required -c/--critical argument"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$WARN_DAYS" =~ ^[0-9]+$ ]]; then
    print_msg "UNKNOWN: -w/--warning must be a non-negative integer, got: '$WARN_DAYS'"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$CRIT_DAYS" =~ ^[0-9]+$ ]]; then
    print_msg "UNKNOWN: -c/--critical must be a non-negative integer, got: '$CRIT_DAYS'"
    exit "$EXIT_UNKNOWN"
fi
if (( WARN_DAYS < CRIT_DAYS )); then
    print_msg "UNKNOWN: -w/--warning ($WARN_DAYS) must be greater than or equal to -c/--critical ($CRIT_DAYS)"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: --timeout must be a positive integer, got: '$TIMEOUT'"
    exit "$EXIT_UNKNOWN"
fi
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    print_msg "UNKNOWN: -j/--jobs must be a positive integer, got: '$JOBS'"
    exit "$EXIT_UNKNOWN"
fi

for tool in curl jq xargs date; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_msg "UNKNOWN: Required tool not found: $tool"
        exit "$EXIT_UNKNOWN"
    fi
done

URL="${URL%/}"

body_file=$(mktemp)
CLIENT_TOKEN=""

cleanup() {
    if [[ -n "$CLIENT_TOKEN" ]]; then
        curl -sS -m "$TIMEOUT" -X POST \
            -H "X-Vault-Token: $CLIENT_TOKEN" \
            "$URL/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
    fi
    rm -f "$body_file"
}
trap cleanup EXIT

# 1. AppRole login
login_payload=$(jq -nc --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id:$r, secret_id:$s}')
http_code=$(curl -sS -m "$TIMEOUT" \
    -o "$body_file" \
    -w '%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    --data "$login_payload" \
    "$URL/v1/auth/$AUTH_PATH/login" 2>/dev/null) || {
    print_msg "UNKNOWN: Failed to reach AppRole login at $URL/v1/auth/$AUTH_PATH/login"
    exit "$EXIT_UNKNOWN"
}

body=$(cat "$body_file")

if [[ "$http_code" =~ ^5 ]] || [[ "$http_code" == "000" ]]; then
    print_msg "UNKNOWN: AppRole login returned HTTP $http_code"
    exit "$EXIT_UNKNOWN"
fi

if [[ "$http_code" != "200" ]]; then
    err_msg=$(echo "$body" | jq -r '.errors // [] | join(", ")' 2>/dev/null)
    print_msg "CRITICAL: AppRole login failed (HTTP $http_code)${err_msg:+: $err_msg}"
    exit "$EXIT_CRITICAL"
fi

CLIENT_TOKEN=$(echo "$body" | jq -r '.auth.client_token // empty' 2>/dev/null)
if [[ -z "$CLIENT_TOKEN" ]]; then
    print_msg "UNKNOWN: AppRole login returned no client_token"
    exit "$EXIT_UNKNOWN"
fi

# 2. List all AppRole roles
http_code=$(curl -sS -m "$TIMEOUT" \
    -o "$body_file" \
    -w '%{http_code}' \
    -X LIST \
    -H "X-Vault-Token: $CLIENT_TOKEN" \
    "$URL/v1/auth/$AUTH_PATH/role" 2>/dev/null) || {
    print_msg "UNKNOWN: Failed to list AppRole roles at $URL/v1/auth/$AUTH_PATH/role"
    exit "$EXIT_UNKNOWN"
}

if [[ "$http_code" == "404" ]]; then
    print_msg "OK: No AppRole roles defined at mount '$AUTH_PATH'"
    exit "$EXIT_OK"
fi

if [[ "$http_code" != "200" ]]; then
    body=$(cat "$body_file")
    err_msg=$(echo "$body" | jq -r '.errors // [] | join(", ")' 2>/dev/null)
    print_msg "UNKNOWN: Failed to list AppRole roles (HTTP $http_code)${err_msg:+: $err_msg}"
    exit "$EXIT_UNKNOWN"
fi

roles_raw=$(jq -r '.data.keys[]?' "$body_file" 2>/dev/null)
if [[ -z "$roles_raw" ]]; then
    print_msg "OK: No AppRole roles found at mount '$AUTH_PATH'"
    exit "$EXIT_OK"
fi

# 3. Apply role include/exclude filters
glob_match()  { [[ "$2" == $1 ]]; }
matches_any() {
    local patterns="$1" value="$2" pat
    for pat in $patterns; do glob_match "$pat" "$value" && return 0; done
    return 1
}

INCLUDE_ROLES_S="${INCLUDE_ROLES[*]+"${INCLUDE_ROLES[*]}"}"
EXCLUDE_ROLES_S="${EXCLUDE_ROLES[*]+"${EXCLUDE_ROLES[*]}"}"

filtered_roles=()
while IFS= read -r role; do
    [[ -z "$role" ]] && continue
    if [[ -n "$INCLUDE_ROLES_S" ]]; then
        matches_any "$INCLUDE_ROLES_S" "$role" || continue
    fi
    if [[ -n "$EXCLUDE_ROLES_S" ]]; then
        matches_any "$EXCLUDE_ROLES_S" "$role" && continue
    fi
    filtered_roles+=("$role")
done <<< "$roles_raw"

if [[ ${#filtered_roles[@]} -eq 0 ]]; then
    print_msg "OK: No AppRole roles match the include/exclude filters"
    exit "$EXIT_OK"
fi

# 4. For each role, list its secret_id accessors. Build a flat list of
#    "role<TAB>accessor" pairs that we then look up in parallel.
pairs_file=$(mktemp)
trap 'rm -f "$body_file" "$pairs_file"; [[ -n "$CLIENT_TOKEN" ]] && curl -sS -m "$TIMEOUT" -X POST -H "X-Vault-Token: $CLIENT_TOKEN" "$URL/v1/auth/token/revoke-self" >/dev/null 2>&1 || true' EXIT

for role in "${filtered_roles[@]}"; do
    http_code=$(curl -sS -m "$TIMEOUT" \
        -o "$body_file" \
        -w '%{http_code}' \
        -X LIST \
        -H "X-Vault-Token: $CLIENT_TOKEN" \
        "$URL/v1/auth/$AUTH_PATH/role/$role/secret-id" 2>/dev/null) || continue

    # 404 = role exists but has no secret_ids — skip silently.
    [[ "$http_code" == "404" ]] && continue

    if [[ "$http_code" != "200" ]]; then
        body=$(cat "$body_file")
        err_msg=$(echo "$body" | jq -r '.errors // [] | join(", ")' 2>/dev/null)
        print_msg "UNKNOWN: Failed to list secret_ids for role '$role' (HTTP $http_code)${err_msg:+: $err_msg}"
        exit "$EXIT_UNKNOWN"
    fi

    while IFS= read -r accessor; do
        [[ -z "$accessor" ]] && continue
        printf '%s\t%s\n' "$role" "$accessor" >> "$pairs_file"
    done < <(jq -r '.data.keys[]?' "$body_file" 2>/dev/null)
done

if [[ ! -s "$pairs_file" ]]; then
    print_msg "OK: No secret_ids issued for the scanned roles"
    exit "$EXIT_OK"
fi

# 5. Per-accessor lookup. Emits TSV: <role>\t<accessor>\t<bucket>\t<days_left>
#    bucket: 'crit' | 'warn' | 'noexp'  (only emits in-window or non-expiring)
lookup_pair() {
    local role="$1" accessor="$2"
    local now; now=$(date +%s)

    local resp http_code raw
    resp=$(curl -sS -m "$TIMEOUT" \
        -X POST \
        -H "X-Vault-Token: $CLIENT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$(jq -nc --arg a "$accessor" '{secret_id_accessor:$a}')" \
        -w $'\n%{http_code}' \
        "$URL/v1/auth/$AUTH_PATH/role/$role/secret-id-accessor/lookup" 2>/dev/null) || return 0

    http_code="${resp##*$'\n'}"
    raw="${resp%$'\n'*}"

    [[ "$http_code" != "200" ]] && return 0
    echo "$raw" | jq -e '.data' &>/dev/null || return 0

    local secret_id_ttl expiration_time
    secret_id_ttl=$(echo "$raw"   | jq -r '.data.secret_id_ttl // 0')
    expiration_time=$(echo "$raw" | jq -r '.data.expiration_time // ""')

    # Bao represents "no expiry" with the Go zero time.
    local has_expiry=1
    if [[ "$secret_id_ttl" -eq 0 ]] || [[ -z "$expiration_time" ]] \
       || [[ "$expiration_time" == "0001-01-01T00:00:00Z" ]] \
       || [[ "$expiration_time" == 0001-01-01* ]]; then
        has_expiry=0
    fi

    if [[ "$has_expiry" -eq 0 ]]; then
        [[ "$SKIP_NO_EXPIRY" -eq 1 ]] && return 0
        printf '%s\t%s\tnoexp\t-\n' "$role" "$accessor"
        return 0
    fi

    local expire_epoch
    expire_epoch=$(date -d "$expiration_time" +%s 2>/dev/null || echo 0)
    [[ "$expire_epoch" -le 0 ]] && return 0

    local remaining=$(( expire_epoch - now ))
    [[ "$remaining" -le 0 ]] && return 0

    local warn_secs=$(( WARN_DAYS * 86400 ))
    local crit_secs=$(( CRIT_DAYS * 86400 ))
    [[ "$remaining" -gt "$warn_secs" ]] && return 0

    local days_left=$(( remaining / 86400 ))
    if [[ "$remaining" -lt "$crit_secs" ]]; then
        printf '%s\t%s\tcrit\t%d\n' "$role" "$accessor" "$days_left"
    else
        printf '%s\t%s\twarn\t%d\n' "$role" "$accessor" "$days_left"
    fi
}

export -f lookup_pair
export URL CLIENT_TOKEN AUTH_PATH TIMEOUT WARN_DAYS CRIT_DAYS SKIP_NO_EXPIRY

results=$(awk -F'\t' '{print $1 "\t" $2}' "$pairs_file" \
    | xargs -P "$JOBS" -L 1 -I{} bash -c 'IFS=$'\''\t'\'' read -r r a <<< "{}"; lookup_pair "$r" "$a"' \
    2>/dev/null | grep -v '^$' || true)

# 6. Classify
crit_list=()
warn_list=()
noexp_list=()

if [[ -n "$results" ]]; then
    while IFS=$'\t' read -r role accessor bucket days_left; do
        [[ -z "$role" ]] && continue
        case "$bucket" in
            crit)  crit_list+=("CRITICAL: AppRole ${role} (accessor=${accessor}) secret ID expires in ${days_left}d (<${CRIT_DAYS}d)") ;;
            warn)  warn_list+=("WARNING: AppRole ${role} (accessor=${accessor}) secret ID expires in ${days_left}d (<${WARN_DAYS}d)") ;;
            noexp) noexp_list+=("CRITICAL: AppRole ${role} (accessor=${accessor}) secret ID never expires") ;;
        esac
    done <<< "$results"
fi

lines=()
[[ ${#crit_list[@]}  -gt 0 ]] && lines+=("${crit_list[@]}")
[[ ${#warn_list[@]}  -gt 0 ]] && lines+=("${warn_list[@]}")
[[ ${#noexp_list[@]} -gt 0 ]] && lines+=("${noexp_list[@]}")

if [[ ${#crit_list[@]} -gt 0 || ${#noexp_list[@]} -gt 0 ]]; then
    rc="$EXIT_CRITICAL"
elif [[ ${#warn_list[@]} -gt 0 ]]; then
    rc="$EXIT_WARNING"
else
    lines=("OK: No approle secret IDs expiring within ${WARN_DAYS}d")
    rc="$EXIT_OK"
fi

msg=$(printf '%s\n' "${lines[@]}")
print_msg "$msg"
exit "$rc"
