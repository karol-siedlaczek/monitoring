#!/bin/bash

# Karol Siedlaczek 2026

CODE_OK=0
CODE_WARN=1
CODE_CRIT=2
CODE_UNKNOWN=3

WARN=10
CRIT=20
INCLUDE=""
EXCLUDE=""
NAGIOS=0
VERBOSE=0
DETAIL=0

HELP() {
    cat <<EOT
Usage: $0 [-i|--include LIST] [-e|--exclude LIST] [-w|--warning N] [-c|--critical N] [-d] [-L] [-n] [-v] [-h]

Check disk health via SMART. For HDD/SATA the bad-sectors metric is the sum of
SMART IDs 5 (Reallocated_Sector_Ct) + 197 (Current_Pending_Sector) +
198 (Offline_Uncorrectable). For NVMe it is Media_and_Data_Integrity_Errors.
The -w/-c thresholds apply to that metric.

Forces CRITICAL regardless of thresholds when:
  - smartctl -H reports overall-health FAILED
  - NVMe Critical Warning != 0x00
  - NVMe Percentage Used >= 100
  - NVMe Available Spare < Available Spare Threshold

Options:
  -i, --include LIST  Comma-separated /dev/disk/by-id/ symlinks to check
                      (mutually exclusive with --exclude).
  -e, --exclude LIST  Comma-separated /dev/disk/by-id/ symlinks to skip from
                      auto-discovery.
  -w, --warning N     Bad-sectors warning threshold (default: 10).
  -c, --critical N    Bad-sectors critical threshold (default: 20).
  -d, --detail        Append "(<details>)" tag to each per-device line with
                      the underlying attribute breakdown (Reallocated/Pending/
                      Offline for ATA, media_errors/percentage_used/available_
                      spare/critical_warning for NVMe) and any marginal
                      attributes (WHEN_FAILED != "-"). Combine with -v to see
                      detail for healthy disks too.
  -L, --legend        Print a glossary describing every SMART metric this
                      check reports (what it means, units, when it forces
                      CRITICAL) and exit. Standalone mode.
  -n, --nagios        Replace newlines with <br/> for Nagios web GUI rendering.
  -v, --verbose       Print one line per disk (including healthy ones).
                      Default prints a single summary line when all disks are
                      healthy, or one line per problematic disk otherwise.
  -h, --help          Show this help and exit.
EOT
    exit $CODE_UNKNOWN
}

LEGEND() {
    cat <<EOT
SMART metrics reported by this check:

ATA / SATA / SCSI rotational disks:
  Reallocated_Sector_Ct       (SMART ID 5)   Sectors permanently remapped to
                                             the spare area after a write/read
                                             failure. Non-zero = wear; growing
                                             over time = failing media.
  Current_Pending_Sector      (SMART ID 197) Sectors that returned a read
                                             error and are queued for
                                             reallocation on the next
                                             successful write. Strong
                                             early-warning indicator.
  Offline_Uncorrectable       (SMART ID 198) Sectors that failed offline read
                                             tests and could not be recovered.
                                             Data-loss risk.
  bad sectors                                Sum of the three counters above;
                                             -w / -c thresholds apply to it.

  Marginal attributes (WHEN_FAILED column):
    "-"            Attribute has never crossed below its threshold.
    "In_the_past"  WORST value was below threshold at some point in history
                   (e.g. brief overheat). Disk is currently fine; reported as
                   informational context only.
    "FAILING_NOW"  Value is currently below threshold. Real concern.

NVMe SSDs:
  Media and Data Integrity Errors  Cumulative count of unrecovered data
                                   integrity errors detected by the
                                   controller (uncorrectable ECC, CRC, etc.).
                                   -w / -c thresholds apply to this counter.
  Critical Warning                 Bitmask from NVMe SMART log byte 0:
                                     0x01 available spare below threshold
                                     0x02 temperature above critical
                                     0x04 NVM subsystem reliability degraded
                                     0x08 media placed in read-only mode
                                     0x10 volatile memory backup failed
                                     0x20 PMR is unreliable
                                   Any non-zero value forces CRITICAL.
  Percentage Used                  NVMe wear indicator: vendor estimate of
                                   how much of the NAND endurance budget
                                   (manufacturer-rated TBW) has been consumed.
                                   NOT capacity utilization. 100% means the
                                   rated endurance is exhausted (drive may
                                   still work) and forces CRITICAL.
  Available Spare                  Percentage of remaining spare NAND blocks
                                   the controller can use for wear-leveling
                                   and bad-block replacement.
  Available Spare Threshold        Vendor-defined floor; if Available Spare
                                   drops below it, CRITICAL is forced.

Forced CRITICAL conditions (regardless of -w / -c):
  - smartctl -H reports overall-health FAILED
  - NVMe Critical Warning != 0x00
  - NVMe Percentage Used >= 100
  - NVMe Available Spare < Available Spare Threshold
EOT
    exit $CODE_UNKNOWN
}

OPTS=$(getopt -o i:e:w:c:dLnvh --long include:,exclude:,warning:,critical:,detail,legend,nagios,verbose,help -- "$@") || HELP
eval set -- "$OPTS"

while true; do
    case "$1" in
        -i|--include) INCLUDE=$2; shift 2;;
        -e|--exclude) EXCLUDE=$2; shift 2;;
        -w|--warning) WARN=$2; shift 2;;
        -c|--critical) CRIT=$2; shift 2;;
        -d|--detail) DETAIL=1; shift;;
        -L|--legend) LEGEND;;
        -n|--nagios) NAGIOS=1; shift;;
        -v|--verbose) VERBOSE=1; shift;;
        -h|--help) HELP;;
        --) shift; break;;
        *) echo "UNKNOWN: Invalid option: $1"; exit $CODE_UNKNOWN;;
    esac
done

if ! [[ "$WARN" =~ ^[0-9]+$ && "$CRIT" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: -w and -c must be non-negative integers"
    exit $CODE_UNKNOWN
fi
if [ "$WARN" -ge "$CRIT" ]; then
    echo "UNKNOWN: -w ($WARN) must be less than -c ($CRIT)"
    exit $CODE_UNKNOWN
fi
if [ -n "$INCLUDE" ] && [ -n "$EXCLUDE" ]; then
    echo "UNKNOWN: --include and --exclude are mutually exclusive"
    exit $CODE_UNKNOWN
fi

SMARTCTL=$(command -v smartctl) || {
    echo "UNKNOWN: smartctl command not found"
    exit $CODE_UNKNOWN
}

declare -A DEV_SEEN
declare -a DEVICES
declare -a UNKNOWN_LINES

resolve_id() {
    local id=$1
    [ -L "$id" ] || return 1
    readlink -f "$id"
}

add_device() {
    local real=$1
    [ -n "${DEV_SEEN[$real]:-}" ] && return
    DEV_SEEN[$real]=1
    DEVICES+=("$real")
}

discover_all() {
    local id bn real
    shopt -s nullglob
    for id in /dev/disk/by-id/*; do
        bn=$(basename "$id")
        [[ "$bn" =~ ^(ata|scsi|nvme)- ]] || continue
        [[ "$bn" =~ -part[0-9]+$ ]] && continue
        real=$(readlink -f "$id") || continue
        add_device "$real"
    done
    shopt -u nullglob
}

if [ -n "$INCLUDE" ]; then
    IFS=',' read -ra ids <<< "$INCLUDE"
    for id in "${ids[@]}"; do
        real=$(resolve_id "$id") || {
            UNKNOWN_LINES+=("UNKNOWN: identifier not found on $id device")
            continue
        }
        add_device "$real"
    done
elif [ -n "$EXCLUDE" ]; then
    declare -A EXCLUDED
    IFS=',' read -ra ids <<< "$EXCLUDE"
    for id in "${ids[@]}"; do
        real=$(resolve_id "$id") || {
            UNKNOWN_LINES+=("UNKNOWN: identifier not found on $id device")
            continue
        }
        EXCLUDED[$real]=1
    done
    discover_all
    declare -a FILTERED
    for d in "${DEVICES[@]}"; do
        [ -n "${EXCLUDED[$d]:-}" ] && continue
        FILTERED+=("$d")
    done
    DEVICES=("${FILTERED[@]}")
else
    discover_all
fi

if [ ${#DEVICES[@]} -gt 0 ]; then
    mapfile -t DEVICES < <(printf '%s\n' "${DEVICES[@]}" | sort -u)
fi

emit() {
    local sep=$'\n'
    [ "$NAGIOS" -eq 1 ] && sep="<br/>"
    local first=1 line
    for line in "$@"; do
        if [ "$first" -eq 1 ]; then
            printf '%s' "$line"
            first=0
        else
            printf '%s%s' "$sep" "$line"
        fi
    done
    printf '\n'
}

if [ ${#DEVICES[@]} -eq 0 ] && [ ${#UNKNOWN_LINES[@]} -eq 0 ]; then
    emit "OK: No devices to check"
    exit $CODE_OK
fi

worst=$CODE_OK
[ ${#UNKNOWN_LINES[@]} -gt 0 ] && worst=$CODE_UNKNOWN

declare -a OK_DEVICES
declare -a DISK_LINES_ALL
declare -a DISK_LINES_PROBS

for dev in "${DEVICES[@]}"; do
    if [[ "$dev" =~ ^/dev/nvme ]]; then
        type=nvme
        smart_dtype="-d nvme"
    else
        info_out=$($SMARTCTL -i "$dev" 2>&1)
        if echo "$info_out" | grep -qi 'NVMe'; then
            type=nvme
            smart_dtype="-d nvme"
        else
            type=ata
            smart_dtype="-d auto"
        fi
    fi

    health_out=$($SMARTCTL -H $smart_dtype "$dev" 2>&1)
    health_rc=$?
    attr_out=$($SMARTCTL -A $smart_dtype "$dev" 2>&1)
    attr_rc=$?

    if (( (health_rc & 3) != 0 )) && (( (attr_rc & 3) != 0 )); then
        line="UNKNOWN: smartctl read failed on $dev device (rc=$health_rc/$attr_rc)"
        DISK_LINES_ALL+=("$line")
        DISK_LINES_PROBS+=("$line")
        [ "$worst" -lt "$CODE_UNKNOWN" ] && worst=$CODE_UNKNOWN
        continue
    fi

    sev=$CODE_OK
    notes=()

    if echo "$health_out" | grep -qE '^SMART (overall-health self-assessment test result|Health Status):[[:space:]]+FAILED'; then
        sev=$CODE_CRIT
        notes+=("SMART overall-health FAILED")
    fi

    bad=0
    reall=0; pend=0; offl=0
    cw=""; pu=""; as=""; ast=""
    if [ "$type" = "ata" ]; then
        reall=$(echo "$attr_out" | awk '$1==5 {print $NF; exit}')
        pend=$(echo "$attr_out" | awk '$1==197 {print $NF; exit}')
        offl=$(echo "$attr_out" | awk '$1==198 {print $NF; exit}')
        [[ "$reall" =~ ^[0-9]+$ ]] || reall=0
        [[ "$pend"  =~ ^[0-9]+$ ]] || pend=0
        [[ "$offl"  =~ ^[0-9]+$ ]] || offl=0
        bad=$((reall + pend + offl))
        unit="bad sectors"
    else
        v=$(echo "$attr_out" | awk -F: '/Media and Data Integrity Errors/ {gsub(/[ ,]/, "", $2); print $2; exit}')
        [[ "$v" =~ ^[0-9]+$ ]] && bad=$v

        cw=$(echo "$attr_out" | awk -F: '/Critical Warning/ {gsub(/ /, "", $2); print $2; exit}')
        if [ -n "$cw" ] && [ "$cw" != "0x00" ] && [ "$cw" != "0" ]; then
            sev=$CODE_CRIT
            notes+=("Critical Warning $cw")
        fi

        pu=$(echo "$attr_out" | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2; exit}')
        if [[ "$pu" =~ ^[0-9]+$ ]] && [ "$pu" -ge 100 ]; then
            sev=$CODE_CRIT
            notes+=("Percentage Used ${pu}%")
        fi

        as=$(echo "$attr_out" | awk -F: '/Available Spare:/ && !/Threshold/ {gsub(/[ %]/, "", $2); print $2; exit}')
        ast=$(echo "$attr_out" | awk -F: '/Available Spare Threshold/ {gsub(/[ %]/, "", $2); print $2; exit}')
        if [[ "$as" =~ ^[0-9]+$ ]] && [[ "$ast" =~ ^[0-9]+$ ]] && [ "$as" -lt "$ast" ]; then
            sev=$CODE_CRIT
            notes+=("Available Spare ${as}% below threshold ${ast}%")
        fi

        unit="media errors"
    fi

    if [ "$bad" -ge "$CRIT" ]; then
        sev=$CODE_CRIT
    elif [ "$bad" -ge "$WARN" ] && [ "$sev" -lt "$CODE_WARN" ]; then
        sev=$CODE_WARN
    fi

    reason_suffix=""
    if [ "$DETAIL" -eq 1 ]; then
        reason_parts=()
        if [ "$type" = "ata" ]; then
            while IFS=$'\t' read -r mname mworst mthresh mwf; do
                [ -n "$mname" ] && reason_parts+=("marginal $mname WORST=$mworst<=THRESH=$mthresh $mwf")
            done < <(echo "$attr_out" | awk '$1 ~ /^[0-9]+$/ && NF >= 10 && $9 != "-" {print $2"\t"$5"\t"$6"\t"$9}')
            reason_parts+=("Reallocated=$reall Pending=$pend Offline=$offl")
        else
            reason_parts+=("media_errors=$bad")
            [ -n "$cw" ] && reason_parts+=("critical_warning=$cw")
            [[ "$pu" =~ ^[0-9]+$ ]] && reason_parts+=("percentage_used=${pu}%")
            if [[ "$as" =~ ^[0-9]+$ ]] && [[ "$ast" =~ ^[0-9]+$ ]]; then
                reason_parts+=("available_spare=${as}%/threshold=${ast}%")
            fi
        fi
        if [ ${#reason_parts[@]} -gt 0 ]; then
            rs=""
            for p in "${reason_parts[@]}"; do
                [ -n "$rs" ] && rs+="; "
                rs+="$p"
            done
            reason_suffix=" ($rs)"
        fi
    fi

    case $sev in
        $CODE_OK)
            OK_DEVICES+=("$dev")
            DISK_LINES_ALL+=("OK: $bad $unit on $dev device${reason_suffix}")
            ;;
        $CODE_WARN)
            line="WARNING: Found $bad $unit on $dev device${reason_suffix}"
            DISK_LINES_ALL+=("$line")
            DISK_LINES_PROBS+=("$line")
            ;;
        $CODE_CRIT)
            if [ ${#notes[@]} -gt 0 ]; then
                IFS=', '; note_str="${notes[*]}"; unset IFS
                line="CRITICAL: $note_str on $dev device, $bad $unit${reason_suffix}"
            else
                line="CRITICAL: Found $bad $unit on $dev device${reason_suffix}"
            fi
            DISK_LINES_ALL+=("$line")
            DISK_LINES_PROBS+=("$line")
            ;;
    esac

    [ "$sev" -gt "$worst" ] && worst=$sev
done

declare -a OUTPUT_LINES
OUTPUT_LINES+=("${UNKNOWN_LINES[@]}")

if [ "$VERBOSE" -eq 1 ]; then
    OUTPUT_LINES+=("${DISK_LINES_ALL[@]}")
else
    if [ "$worst" -eq "$CODE_OK" ]; then
        IFS=','; list="${OK_DEVICES[*]}"; unset IFS
        OUTPUT_LINES+=("OK: No issues detected on devices $list")
    else
        OUTPUT_LINES+=("${DISK_LINES_PROBS[@]}")
    fi
fi

emit "${OUTPUT_LINES[@]}"
exit $worst
