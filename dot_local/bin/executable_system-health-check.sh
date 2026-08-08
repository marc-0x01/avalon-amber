#!/usr/bin/env bash
#
# system-health-check.sh - read-only diagnostic snapshot of this machine.
#
# Makes NO changes to the system - every check here is purely
# informational. Some checks (runit service status, firewall rules,
# SMART) need root to read; when run as a normal user those checks
# print a one-line "needs root" notice and are skipped rather than
# failing outright, so this is always safe/useful to run either way.
#
# Usage: system-health-check.sh [-h|--help]
#   -h, --help  show this help and exit
#
# Exit codes: 0 = everything checked out OK
#             1 = completed, at least one WARN
#             2 = completed, at least one FAIL
#
# ============================================================

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=system-lib.sh
source "${script_dir}/system-lib.sh"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            # Print the header comment block (everything between the
            # shebang and the "====" divider) instead of duplicating
            # this usage text a second time in the script body.
            sed -n '2,/^# ====/p' "$0" | sed '$d; s/^# \{0,1\}//'
            exit 0
            ;;
        *)
            log_fail "Unknown argument: $arg (see --help)"
            exit 2
            ;;
    esac
done

# --- 1. Disk usage ---
check_disk_usage() {
    log_info "-- Disk usage --"
    # -x excludes pseudo filesystems (tmpfs/devtmpfs/overlay/squashfs)
    # that aren't meaningful "is this disk full" targets.
    # tail -n +2 drops the header row.
    while read -r fs type size used avail pct mount; do
        local pct_num="${pct%\%}"
        if (( pct_num >= 95 )); then
            log_fail "Disk $mount ($fs, $type): $pct used ($used/$size)"
        elif (( pct_num >= 85 )); then
            log_warn "Disk $mount ($fs, $type): $pct used ($used/$size)"
        else
            log_ok "Disk $mount ($fs, $type): $pct used ($used/$size)"
        fi
    done < <(df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2)
}

# --- 2. Disk health (SMART) ---
check_smart() {
    log_info "-- Disk health (SMART) --"
    if ! have_cmd smartctl; then
        log_info "skipped - smartctl not installed."
        return
    fi
    if (( EUID != 0 )); then
        log_info "skipped - needs root (re-run with sudo for full checks)."
        return
    fi
    local disk found=0
    # TYPE=="disk" excludes partitions (nvme0n1p1) and loop devices,
    # leaving just the real physical disks (nvme0n1, sda, ...).
    while read -r disk; do
        found=1
        if smartctl -H "/dev/$disk" 2>/dev/null | grep -qi 'PASSED\|^Overall-health.*OK'; then
            log_ok "SMART $disk: healthy."
        else
            log_fail "SMART $disk: not reporting healthy - check 'sudo smartctl -a /dev/$disk' manually."
        fi
    done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    (( found == 0 )) && log_info "no physical disks found."
}

# --- 3. Memory / swap ---
check_memory() {
    log_info "-- Memory / swap --"
    local total avail swap_total swap_used
    read -r total avail < <(free -m | awk '/^Mem:/{print $2, $7}')
    read -r swap_total swap_used < <(free -m | awk '/^Swap:/{print $2, $3}')

    local avail_pct=$(( avail * 100 / total ))
    if (( avail_pct < 10 )); then
        log_fail "Memory: only ${avail_pct}% available (${avail}MiB / ${total}MiB)."
    elif (( avail_pct < 20 )); then
        log_warn "Memory: ${avail_pct}% available (${avail}MiB / ${total}MiB)."
    else
        log_ok "Memory: ${avail_pct}% available (${avail}MiB / ${total}MiB)."
    fi

    if (( swap_total > 0 )); then
        local swap_pct=$(( swap_used * 100 / swap_total ))
        if (( swap_pct > 50 )); then
            log_warn "Swap: ${swap_pct}% used (${swap_used}MiB / ${swap_total}MiB) - possible memory pressure."
        else
            log_ok "Swap: ${swap_pct}% used (${swap_used}MiB / ${swap_total}MiB)."
        fi
    else
        # Not fatal (plenty of systems run swapless on purpose), but
        # worth a flag since it removes a safety net against OOM.
        log_warn "Swap: none configured."
    fi
}

# --- 4. Temperature ---
check_temperature() {
    log_info "-- Temperature --"
    if ! have_cmd sensors; then
        log_info "skipped - lm_sensors not installed."
        return
    fi
    # Only match "tempN_input" keys specifically (not fanN_input,
    # inN_input, powerN_input, which sensors -u also reports and
    # which are on totally different scales).
    local max_temp
    max_temp="$(sensors -u 2>/dev/null | awk '$1 ~ /^temp[0-9]+_input:/{print $2}' | sort -rn | head -n1 || true)"
    if [[ -z "$max_temp" ]]; then
        log_warn "sensors installed but no temperature readings found - try 'sudo sensors-detect'."
        return
    fi
    local max_temp_int="${max_temp%%.*}"
    if (( max_temp_int >= 90 )); then
        log_fail "Temperature: hottest sensor at ${max_temp}C."
    elif (( max_temp_int >= 75 )); then
        log_warn "Temperature: hottest sensor at ${max_temp}C."
    else
        log_ok "Temperature: hottest sensor at ${max_temp}C."
    fi
}

# --- 5. runit service status ---
check_runit_services() {
    log_info "-- runit services --"
    if (( EUID != 0 )); then
        log_info "skipped - needs root (re-run with sudo for full checks)."
        return
    fi
    local svc_path svc down_count=0
    for svc_path in /var/service/*; do
        svc="$(basename "$svc_path")"
        if ! sv status "$svc_path" 2>/dev/null | grep -q '^run:'; then
            down_count=$(( down_count + 1 ))
            log_fail "service '$svc' is not running: $(sv status "$svc_path" 2>&1)"
        fi
    done
    # Deliberately not printing one OK line per service (22+ of them) -
    # a single summary line is enough signal when everything's fine.
    (( down_count == 0 )) && log_ok "all enabled services are running."
}

# --- 6. Firewall ---
check_firewall() {
    log_info "-- Firewall --"
    if (( EUID != 0 )); then
        log_info "skipped - needs root (re-run with sudo for full checks)."
        return
    fi
    local entry cmd label rule_count
    for entry in "iptables:IPv4" "ip6tables:IPv6"; do
        cmd="${entry%%:*}"
        label="${entry##*:}"
        if [[ ! -L "/var/service/${cmd}" ]]; then
            log_warn "$label: $cmd service is not enabled."
            continue
        fi
        # -S dumps rules including "-P <chain> <policy>" default-policy
        # lines; excluding those counts only actual custom rules.
        rule_count="$("$cmd" -S 2>/dev/null | grep -cv '^-P' || true)"
        if (( rule_count > 0 )); then
            log_ok "$label: $cmd enabled, $rule_count custom rule(s) loaded."
        else
            log_warn "$label: $cmd enabled but no custom rules loaded (default policies only)."
        fi
    done
}

# --- 7. Package state ---
check_package_state() {
    log_info "-- Package state --"
    local pending orphans
    pending="$(xbps-install -Sun 2>/dev/null | grep -c '^' || true)"
    if (( pending > 0 )); then
        log_warn "xbps: $pending package(s) have pending updates (run system-update.sh)."
    else
        log_ok "xbps: no pending updates."
    fi

    orphans="$(xbps-query -O 2>/dev/null | grep -c '^' || true)"
    if (( orphans > 0 )); then
        log_warn "xbps: $orphans orphaned package(s) (run system-periodic-maintenance.sh)."
    else
        log_ok "xbps: no orphaned packages."
    fi
}

# --- 8. Network connectivity ---
check_network() {
    log_info "-- Network --"
    local gateway
    gateway="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || true)"
    if [[ -z "$gateway" ]]; then
        log_fail "no default route found."
        return
    fi
    if ! ping -c1 -W2 "$gateway" >/dev/null 2>&1; then
        log_fail "gateway ($gateway) unreachable."
        return
    fi
    log_ok "gateway ($gateway) reachable."

    # Only tried after the gateway check passes, so a DNS/upstream
    # outage is distinguished from a purely local link problem.
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        log_ok "internet (1.1.1.1) reachable."
    else
        log_warn "gateway OK but internet unreachable."
    fi
}

# --- 9. Load average ---
check_load() {
    log_info "-- Load average --"
    local load1 cores
    load1="$(awk '{print $1}' /proc/loadavg)"
    cores="$(nproc)"
    # bash can't do floating-point comparisons natively; awk can.
    if awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
        log_warn "load average $load1 exceeds core count ($cores)."
    else
        log_ok "load average $load1 (cores: $cores)."
    fi
}

check_disk_usage
check_smart
check_memory
check_temperature
check_runit_services
check_firewall
check_package_state
check_network
check_load

echo
case "$SYS_EXIT_CODE" in
    0) log_ok "Health check complete - no issues found." ;;
    1) log_warn "Health check complete - warnings above." ;;
    *) log_fail "Health check complete - failures above." ;;
esac

sys_log health-check "exit=$SYS_EXIT_CODE"
exit "$SYS_EXIT_CODE"
