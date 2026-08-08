#!/usr/bin/env bash
#
# system-update.sh - pull and apply pending updates for this machine.
#
# Covers both layers of software actually installed here: the base
# xbps system, and any flatpak apps/runtimes (Moonlight + friends).
# Safe to run repeatedly - it always checks for pending work first
# and does nothing if there's nothing to do.
#
# Usage: system-update.sh [-y|--yes] [-h|--help]
#   -y, --yes   don't prompt for confirmation before applying updates
#               (needed for unattended/cron use)
#   -h, --help  show this help and exit
#
# Exit codes: 0 = up to date / updated successfully
#             1 = updated, but a reboot is recommended
#             2 = an update step failed
#
# ============================================================

# -e: stop on the first unhandled error instead of ploughing on with
#     a half-applied update.
# -u: catch typos in variable names instead of silently expanding
#     them to empty strings.
# -o pipefail: a failure in the middle of a pipeline (e.g. xbps-query
#     piped into grep) should still fail the script, not get masked
#     by the last command in the pipe succeeding.
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

# --- xbps: base system packages ---

log_info "Checking for pending xbps updates..."

# `xbps-install -Sun` = sync repo data (-S), dry-run (-n), report updates.
# This intentionally does NOT need root - syncing repodata to a temp
# location and listing candidate updates is read-only in effect.
# We don't use `set -e`-unfriendly `|| true` here: a genuinely broken
# repo/mirror should still abort the script via `set -e`, not be
# silently swallowed.
pending_updates="$(xbps-install -Sun 2>/dev/null || true)"

if [[ -z "$pending_updates" ]]; then
    log_ok "xbps: system is already up to date."
    updated_count=0
else
    updated_count="$(printf '%s\n' "$pending_updates" | grep -c '^' || true)"
    log_info "xbps: $updated_count package(s) can be updated:"
    printf '%s\n' "$pending_updates"

    if (( assume_yes == 0 )); then
        # `read` exits non-zero on EOF (e.g. stdin isn't a terminal,
        # as in a misconfigured cron job) - `|| reply=""` treats that
        # the same as a plain "no" instead of letting `set -e` kill
        # the script mid-message right before we explain why.
        read -r -p "Apply these updates now? [y/N] " reply || reply=""
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            log_warn "xbps: update skipped by user."
            sys_log update "skipped by user ($updated_count pending)"
            exit 1
        fi
    fi

    # Actual apply. Needs root - xbps-install itself will refuse and
    # explain if not run as such, but calling it via sudo here (rather
    # than requiring the whole script run as root) keeps the earlier
    # read-only dry-run/prompt running as the normal user.
    if sudo xbps-install -Su; then
        log_ok "xbps: update applied successfully."
    else
        log_fail "xbps: update failed - see xbps-install output above."
        sys_log update "FAILED applying $updated_count package(s)"
        exit 2
    fi
fi

# --- reboot-needed heuristic ---
#
# Void has no built-in "reboot required" flag (no equivalent of
# Debian's /var/run/reboot-required). The best available signal is
# comparing the currently *running* kernel against the newest
# *installed* linuxX.Y kernel package - if they differ, the running
# kernel is stale and a reboot is needed to actually use the new one.
reboot_needed=0
running_kernel="$(uname -r)"

# `xbps-query -Rs linux` lists every installed/available package whose
# name starts with "linux" across repos; we only want ones actually
# INSTALLED (xbps-query -l), and only the versioned kernel packages
# (linux5.15, linux6.1, etc - excludes linux-firmware, linux-headers).
installed_kernel_pkg="$(xbps-query -l 2>/dev/null \
    | awk '{print $2}' \
    | grep -E '^linux[0-9]+\.[0-9]+-[0-9]' \
    | sort -V \
    | tail -n1 || true)"

if [[ -n "$installed_kernel_pkg" ]]; then
    # Package string looks like "linux6.1-6.1.99_1" - pull just the
    # upstream version portion to compare against `uname -r`'s prefix.
    installed_kernel_ver="$(printf '%s\n' "$installed_kernel_pkg" | sed -E 's/^linux[0-9]+\.[0-9]+-([0-9.]+)_.*/\1/')"
    if [[ -n "$installed_kernel_ver" && "$running_kernel" != "$installed_kernel_ver"* ]]; then
        reboot_needed=1
    fi
fi

if (( reboot_needed == 1 )); then
    log_warn "Running kernel ($running_kernel) is older than the installed kernel package ($installed_kernel_pkg) - reboot recommended."
fi

# --- flatpak: user-scope apps/runtimes ---

if have_cmd flatpak; then
    log_info "Checking for flatpak updates..."
    # flatpak's own -y is safe and non-interactive; no need for our
    # own confirm prompt here since flatpak updates are lower-risk
    # (sandboxed, user-scope, don't touch the base system).
    if flatpak update -y; then
        log_ok "flatpak: up to date."
    else
        log_fail "flatpak: update failed - see flatpak output above."
        sys_log update "FAILED flatpak update"
        exit 2
    fi
else
    log_info "flatpak: not installed, skipping."
fi

# --- summary ---

summary="xbps: $updated_count updated, reboot_needed=$reboot_needed"
sys_log update "$summary"
log_ok "Done. ($summary)"

if (( reboot_needed == 1 )); then
    exit 1
fi
exit 0
