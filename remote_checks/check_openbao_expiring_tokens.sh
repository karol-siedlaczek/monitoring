#!/usr/bin/env bash
# =============================================================================
# Nagios-compatible check for expiring OpenBao tokens.
# Authenticates via AppRole, lists all token accessors and reports those
# whose remaining TTL falls below the warn/critical thresholds.
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
WARN_DAYS=14
CRIT_DAYS=7
BAO_ADDR="${BAO_ADDR:-}"
ROLE_ID="${ROLE_ID:-${BAO_ROLE_ID:-}}"
SECRET_ID="${SECRET_ID:-${BAO_SECRET_ID:-}}"
AUTH_PATH="approle"
PARALLEL_JOBS=5
MIN_TTL_SECS=0
TIMEOUT=10
NAGIOS_MODE=0
CLIENT_TOKEN=""

# Nagios exit codes
OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3

# Filter arrays
EXCLUDE_NAMES=()
INCLUDE_NAMES=()
EXCLUDE_AUTHS=()
INCLUDE_AUTHS=()
EXCLUDE_POLICIES=()
INCLUDE_POLICIES=()
EXCLUDE_PATHS=(ldap/)
INCLUDE_PATHS=()

# -----------------------------------------------------------------------------
# ARGUMENT PARSING
# -----------------------------------------------------------------------------
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
  -j, --jobs N             Parallel lookup jobs                 (default: $PARALLEL_JOBS)
  -t, --timeout N          HTTP timeout in seconds              (default: $TIMEOUT)

Filtering (globs supported, repeatable):
  --exclude-name PATTERN   Exclude tokens by display_name
  --include-name PATTERN   Include ONLY tokens by display_name
  --exclude-auth PATTERN   Exclude tokens by auth method
  --include-auth PATTERN   Include ONLY tokens by auth method
  --exclude-policy PATTERN Exclude tokens matching policy name
  --include-policy PATTERN Include ONLY tokens matching policy
  --exclude-path PATTERN   Exclude tokens by creation path
  --include-path PATTERN   Include ONLY tokens by creation path
  --min-ttl-secs N         Exclude tokens with creation TTL below N seconds

Output:
  -n, --nagios             Replace newlines with <br/> for Nagios web UI

Examples:
  $0 --include-path 'auth/token/create' --include-path 'auth/approle/login'
  $0 --exclude-path 'auth/ldap/*' --exclude-path 'auth/userpass/*'
EOF
  exit $UNKNOWN
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--warning)        WARN_DAYS="$2";           shift 2 ;;
    -c|--critical)       CRIT_DAYS="$2";           shift 2 ;;
    -u|--url)            BAO_ADDR="$2";            shift 2 ;;
    -R|--role-id)        ROLE_ID="$2";             shift 2 ;;
    -S|--secret-id)      SECRET_ID="$2";           shift 2 ;;
    -A|--auth-path)      AUTH_PATH="$2";           shift 2 ;;
    -j|--jobs)           PARALLEL_JOBS="$2";       shift 2 ;;
    -t|--timeout)        TIMEOUT="$2";             shift 2 ;;
    --exclude-name)      EXCLUDE_NAMES+=("$2");    shift 2 ;;
    --include-name)      INCLUDE_NAMES+=("$2");    shift 2 ;;
    --exclude-auth)      EXCLUDE_AUTHS+=("$2");    shift 2 ;;
    --include-auth)      INCLUDE_AUTHS+=("$2");    shift 2 ;;
    --exclude-policy)    EXCLUDE_POLICIES+=("$2"); shift 2 ;;
    --include-policy)    INCLUDE_POLICIES+=("$2"); shift 2 ;;
    --exclude-path)      EXCLUDE_PATHS+=("$2");    shift 2 ;;
    --include-path)      INCLUDE_PATHS+=("$2");    shift 2 ;;
    --min-ttl-secs)      MIN_TTL_SECS="$2";        shift 2 ;;
    -n|--nagios)         NAGIOS_MODE=1;            shift ;;
    -h|--help)           usage ;;
    *) echo "UNKNOWN: Unrecognized option: $1"; exit $UNKNOWN ;;
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

export BAO_ADDR MIN_TTL_SECS ROLE_ID SECRET_ID AUTH_PATH TIMEOUT

export EXCLUDE_NAMES_S="${EXCLUDE_NAMES[*]+"${EXCLUDE_NAMES[*]}"}"
export INCLUDE_NAMES_S="${INCLUDE_NAMES[*]+"${INCLUDE_NAMES[*]}"}"
export EXCLUDE_AUTHS_S="${EXCLUDE_AUTHS[*]+"${EXCLUDE_AUTHS[*]}"}"
export INCLUDE_AUTHS_S="${INCLUDE_AUTHS[*]+"${INCLUDE_AUTHS[*]}"}"
export EXCLUDE_POLICIES_S="${EXCLUDE_POLICIES[*]+"${EXCLUDE_POLICIES[*]}"}"
export INCLUDE_POLICIES_S="${INCLUDE_POLICIES[*]+"${INCLUDE_POLICIES[*]}"}"
export EXCLUDE_PATHS_S="${EXCLUDE_PATHS[*]+"${EXCLUDE_PATHS[*]}"}"
export INCLUDE_PATHS_S="${INCLUDE_PATHS[*]+"${INCLUDE_PATHS[*]}"}"

# -----------------------------------------------------------------------------
# DEPENDENCY CHECK
# -----------------------------------------------------------------------------
for cmd in curl jq xargs date; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "UNKNOWN: Missing dependency: $cmd"
    exit $UNKNOWN
  fi
done

# -----------------------------------------------------------------------------
# VALIDATION
# -----------------------------------------------------------------------------
if [[ -z "$BAO_ADDR" ]]; then
  echo "UNKNOWN: url not set (use -u/--url or set BAO_ADDR)"
  exit $UNKNOWN
fi
if [[ -z "$ROLE_ID" ]]; then
  echo "UNKNOWN: role_id not set (use -R/--role-id or set BAO_ROLE_ID)"
  exit $UNKNOWN
fi
if [[ -z "$SECRET_ID" ]]; then
  echo "UNKNOWN: secret_id not set (use -S/--secret-id or set BAO_SECRET_ID)"
  exit $UNKNOWN
fi
if [[ $CRIT_DAYS -ge $WARN_DAYS ]]; then
  echo "UNKNOWN: CRITICAL threshold ($CRIT_DAYS) must be lower than WARNING ($WARN_DAYS)"
  exit $UNKNOWN
fi

# -----------------------------------------------------------------------------
# APPROLE LOGIN + TOKEN REVOKE TRAP
# -----------------------------------------------------------------------------
body_file=$(mktemp)

cleanup() {
  if [[ -n "$CLIENT_TOKEN" ]]; then
    curl -sS -m "$TIMEOUT" -X POST \
      -H "X-Vault-Token: $CLIENT_TOKEN" \
      "$BAO_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  fi
  rm -f "$body_file"
}
trap cleanup EXIT

login_payload=$(jq -nc --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id:$r,secret_id:$s}')
http_code=$(curl -sS -m "$TIMEOUT" \
  -o "$body_file" -w '%{http_code}' \
  -X POST -H "Content-Type: application/json" \
  --data "$login_payload" \
  "$BAO_ADDR/v1/auth/$AUTH_PATH/login" 2>/dev/null) || {
  echo "UNKNOWN: Cannot reach AppRole login at $BAO_ADDR/v1/auth/$AUTH_PATH/login"
  exit $UNKNOWN
}

if [[ "$http_code" != "200" ]]; then
  err=$(jq -r '.errors//[]|join(", ")' "$body_file" 2>/dev/null)
  echo "UNKNOWN: AppRole login failed (HTTP $http_code)${err:+: $err}"
  exit $UNKNOWN
fi

CLIENT_TOKEN=$(jq -r '.auth.client_token // empty' "$body_file" 2>/dev/null)
if [[ -z "$CLIENT_TOKEN" ]]; then
  echo "UNKNOWN: AppRole login returned no client_token"
  exit $UNKNOWN
fi

export BAO_TOKEN="$CLIENT_TOKEN"

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
glob_match()  { [[ "$2" == $1 ]]; }
matches_any() {
  local patterns="$1" value="$2" pat
  for pat in $patterns; do glob_match "$pat" "$value" && return 0; done
  return 1
}
parse_expire_time() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && echo 0 && return
  date -d "$ts" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null \
    || echo 0
}
export -f glob_match matches_any parse_expire_time

# -----------------------------------------------------------------------------
# TOKEN LOOKUP
# -----------------------------------------------------------------------------
lookup_accessor() {
  local accessor="$1"
  local now; now=$(date +%s)

  local resp http_code raw
  resp=$(curl -sS -m "$TIMEOUT" \
    -X POST \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg a "$accessor" '{accessor:$a}')" \
    -w $'\n%{http_code}' \
    "$BAO_ADDR/v1/auth/token/lookup-accessor" 2>/dev/null) || return 0

  http_code="${resp##*$'\n'}"
  raw="${resp%$'\n'*}"

  [[ "$http_code" != "200" ]] && return 0
  echo "$raw" | jq -e '.data' &>/dev/null || return 0

  local ttl expire_time display_name creation_ttl auth_type policies_json creation_path remaining

  ttl=$(echo "$raw"           | jq -r '.data.ttl // 0')
  expire_time=$(echo "$raw"   | jq -r '.data.expire_time // "null"')
  display_name=$(echo "$raw"  | jq -r '.data.display_name // ""')
  creation_ttl=$(echo "$raw"  | jq -r '.data.creation_ttl // 0')
  auth_type=$(echo "$raw"     | jq -r '.data.meta.auth_type // .data.meta.mount_type // ""')
  policies_json=$(echo "$raw" | jq -r '[.data.policies[]?] | join(" ")')
  creation_path=$(echo "$raw" | jq -r '.data.path // ""')

  [[ "$ttl" -eq 0 && "$expire_time" == "null" ]] && return 0

  if [[ $MIN_TTL_SECS -gt 0 && $creation_ttl -gt 0 && $creation_ttl -lt $MIN_TTL_SECS ]]; then
    return 0
  fi

  # Include filters (whitelist)
  if [[ -n "$INCLUDE_PATHS_S" ]];    then matches_any "$INCLUDE_PATHS_S"    "$creation_path" || return 0; fi
  if [[ -n "$INCLUDE_NAMES_S" ]];    then matches_any "$INCLUDE_NAMES_S"    "$display_name"  || return 0; fi
  if [[ -n "$INCLUDE_AUTHS_S" ]];    then matches_any "$INCLUDE_AUTHS_S"    "$auth_type"     || return 0; fi
  if [[ -n "$INCLUDE_POLICIES_S" ]]; then
    local matched=0 pol
    for pol in $policies_json; do matches_any "$INCLUDE_POLICIES_S" "$pol" && matched=1 && break; done
    [[ $matched -eq 0 ]] && return 0
  fi

  # Exclude filters (blacklist)
  if [[ -n "$EXCLUDE_PATHS_S" ]];    then matches_any "$EXCLUDE_PATHS_S"    "$creation_path" && return 0; fi
  if [[ -n "$EXCLUDE_NAMES_S" ]];    then matches_any "$EXCLUDE_NAMES_S"    "$display_name"  && return 0; fi
  if [[ -n "$EXCLUDE_AUTHS_S" ]];    then matches_any "$EXCLUDE_AUTHS_S"    "$auth_type"     && return 0; fi
  if [[ -n "$EXCLUDE_POLICIES_S" ]]; then
    local pol
    for pol in $policies_json; do matches_any "$EXCLUDE_POLICIES_S" "$pol" && return 0; done
  fi

  # Compute remaining TTL
  if [[ "$expire_time" != "null" && -n "$expire_time" ]]; then
    local expire_epoch
    expire_epoch=$(parse_expire_time "$expire_time")
    remaining=$(( expire_epoch - now ))
  elif [[ "$ttl" -gt 0 ]]; then
    remaining=$ttl
  else
    return 0
  fi

  local warn_secs=$(( WARN_DAYS * 86400 ))
  [[ $remaining -gt $warn_secs ]] && return 0
  [[ $remaining -le 0 ]] && return 0

  local days_left=$(( remaining / 86400 ))
  printf '%s\t%s\t%d\n' "$accessor" "$display_name" "$days_left"
}

export -f lookup_accessor
export WARN_DAYS CRIT_DAYS

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
http_code=$(curl -sS -m "$TIMEOUT" \
  -o "$body_file" -w '%{http_code}' \
  -X LIST \
  -H "X-Vault-Token: $CLIENT_TOKEN" \
  "$BAO_ADDR/v1/auth/token/accessors" 2>/dev/null) || {
  echo "UNKNOWN: Failed to reach OpenBao at $BAO_ADDR"
  exit $UNKNOWN
}

if [[ "$http_code" != "200" ]]; then
  err=$(jq -r '.errors//[]|join(", ")' "$body_file" 2>/dev/null)
  echo "UNKNOWN: Failed to list token accessors (HTTP $http_code)${err:+: $err}"
  exit $UNKNOWN
fi

accessors=$(jq -r '.data.keys[]?' "$body_file" 2>/dev/null)

results=$(echo "$accessors" \
  | xargs -P "$PARALLEL_JOBS" -I{} bash -c 'lookup_accessor "$@"' _ {} 2>/dev/null \
  | grep -v '^$' || true)

# Classify
crit_list=()
warn_list=()

while IFS=$'\t' read -r accessor display days_left; do
  [[ -z "$accessor" ]] && continue
  local_display="${display:-N/A}"
  if [[ $days_left -lt $CRIT_DAYS ]]; then
    crit_list+=("${accessor} (${local_display}, ${days_left}d)")
  else
    warn_list+=("${accessor} (${local_display}, ${days_left}d)")
  fi
done <<< "$results"

crit_count=${#crit_list[@]}
warn_count=${#warn_list[@]}

if [[ $crit_count -gt 0 && $warn_count -gt 0 ]]; then
  msg="CRITICAL: Tokens expiring within ${CRIT_DAYS}d: $(IFS=', '; echo "${crit_list[*]}") | WARNING: Tokens expiring within ${WARN_DAYS}d: $(IFS=', '; echo "${warn_list[*]}")"
  rc=$CRITICAL
elif [[ $crit_count -gt 0 ]]; then
  msg="CRITICAL: Tokens expiring within ${CRIT_DAYS}d: $(IFS=', '; echo "${crit_list[*]}")"
  rc=$CRITICAL
elif [[ $warn_count -gt 0 ]]; then
  msg="WARNING: Tokens expiring within ${WARN_DAYS}d: $(IFS=', '; echo "${warn_list[*]}")"
  rc=$WARNING
else
  msg="OK: No tokens expiring within ${WARN_DAYS}d"
  rc=$OK
fi

print_msg "$msg"
exit $rc
