#!/usr/bin/env bash
#
# system-periodic-maintenance.sh - routine cleanup, safe to run
# unattended from cron. Idempotent: running it back-to-back with
# nothing new to clean is a no-op, not an error.
#
# This script is EUID-gated rather than split into two files:
#   - Run as root (e.g. from root's crontab): does the xbps/kernel/
#     trim housekeeping that needs root, skips the flatpak step.
#   - Run as the normal user (e.g. from the user's crontab): does
#     the flatpak cleanup (flatpak here is a user-scope install
#     under ~/.local/share/flatpak - running it as root would either
#     no-op or touch the wrong install directory entirely), skips
#     the root-only steps.
# Both halves print a one-line "skipped - wrong EUID for this step"
# style notice rather than silently doing nothing, so a human
# reading the log can tell it behaved as expected.
#
# Usage: system-periodic-maintenance.sh [-y|--yes] [-h|--help]
#   -y, --yes   don't prompt for confirmation (needed for cron use)
#   -h, --help  show this help and exit
#
# Exit codes: 0 = completed with nothing to flag
#             1 = completed, at least one WARN
#             2 = a cleanup step failed
#
# ============================================================

set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=system-lib.sh
source "${script_dir}/system-lib.sh"

assume_yes=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            assume_yes=1
            ;;
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

# xbps-remove's own -y flag; only pass it through when we were asked
# to run non-interactively, so an interactive run still gets xbps's
# normal "are you sure" prompts.
xbps_yes_flag=()
(( assume_yes == 1 )) && xbps_yes_flag=(-y)

# --- root-scoped steps ---
run_root_steps() {
    if (( EUID != 0 )); then
        log_info "root-scoped steps skipped - not running as root (re-run via sudo/root cron for these)."
        return
    fi

    # fstrim: tells the NVMe SSD which blocks are free so its
    # controller can garbage-collect them ahead of time. Safe to run
    # anytime; a no-op on filesystems with nothing new to trim.
    log_info "-- fstrim --"
    if fstrim -av; then
        log_ok "fstrim completed."
    else
        log_fail "fstrim failed."
    fi

    # Orphaned packages: dependencies that were pulled in for
    # something now-removed and are no longer required by anything.
    log_info "-- xbps orphaned packages --"
    local orphans
    orphans="$(xbps-query -O 2>/dev/null | grep -c '^' || true)"
    if (( orphans == 0 )); then
        log_ok "no orphaned packages."
    else
        log_info "$orphans orphaned package(s) found, removing..."
        if xbps-remove -o "${xbps_yes_flag[@]}"; then
            log_ok "orphaned packages removed."
        else
            log_fail "removing orphaned packages failed."
        fi
    fi

    # Old kernels: Void keeps every installed kernel package around
    # (for rollback) until explicitly purged. `vkpurge list` already
    # excludes whichever kernel is currently running, so `rm all` is
    # safe - it can never remove the kernel actually in use.
    log_info "-- old kernel packages (vkpurge) --"
    local old_kernels
    old_kernels="$(vkpurge list 2>/dev/null || true)"
    if [[ -z "$old_kernels" ]]; then
        log_ok "no old kernel packages to purge."
    else
        log_info "old kernel(s) found:"
        printf '%s\n' "$old_kernels"
        if vkpurge rm all; then
            log_ok "old kernels purged."
        else
            log_fail "vkpurge failed."
        fi
    fi

    # Package cache: -O removes outdated (superseded-by-a-newer-
    # version) binary packages from /var/cache/xbps. Deliberately NOT
    # doubling this flag (which would also purge uninstalled-package
    # binpkgs) - that would remove the ability to reinstall/downgrade
    # something without re-downloading it, which is more aggressive
    # than a routine "clean stale stuff" job should be.
    log_info "-- xbps package cache --"
    if xbps-remove -O "${xbps_yes_flag[@]}"; then
        log_ok "package cache cleaned."
    else
        log_fail "cleaning package cache failed."
    fi
}

# --- user-scoped steps ---
run_user_steps() {
    if (( EUID == 0 )); then
        log_info "user-scoped steps skipped - running as root (re-run as your normal user for these)."
        return
    fi

    log_info "-- flatpak unused runtimes --"
    if ! have_cmd flatpak; then
        log_info "flatpak not installed, skipping."
        return
    fi
    if flatpak uninstall --unused -y; then
        log_ok "flatpak cleanup completed."
    else
        log_fail "flatpak cleanup failed."
    fi
}

run_root_steps
run_user_steps

echo
case "$SYS_EXIT_CODE" in
    0) log_ok "Periodic maintenance complete - nothing to flag." ;;
    1) log_warn "Periodic maintenance complete - warnings above." ;;
    *) log_fail "Periodic maintenance complete - failures above." ;;
esac

sys_log periodic-maintenance "euid=$EUID exit=$SYS_EXIT_CODE"
exit "$SYS_EXIT_CODE"
