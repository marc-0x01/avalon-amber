# ============================================================
# system-lib.sh - shared helpers for the system-*.sh scripts.
#
# This file is a LIBRARY: it must be `source`d, never executed
# directly (it has no shebang on purpose - running it as its own
# process would just define functions in a subshell and throw
# them away). Every system-*.sh script sources it like this:
#
#   script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
#   # shellcheck source=system-lib.sh
#   source "${script_dir}/system-lib.sh"
#
# using readlink -f so it still finds this file correctly no
# matter how the calling script was invoked (absolute path,
# relative path, or found via $PATH).
# ============================================================

# Refuse to run standalone - this file only makes sense sourced into
# another script's shell, since it shares that script's variables
# (SYS_EXIT_CODE, SYS_LOG_NAME) and exit-code contract.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "system-lib.sh is a library - source it from another script, don't run it directly." >&2
    exit 2
fi

# Force the C locale for every command these scripts shell out to.
# This machine runs fr_CH.UTF-8, which translates some tool output
# (e.g. `free` labels "Swap:" as "Échange:") - without this, locale-
# sensitive parsing (grep/awk matching on English keywords) silently
# breaks depending on who/how the script is invoked. Set once here so
# every system-*.sh script gets consistent, parseable output for free.
export LC_ALL=C

# ---- exit-code contract shared by every system-*.sh script ----
# 0 = success / all clear
# 1 = completed, but with warnings worth a human's attention
# 2 = failure / error
#
# SYS_EXIT_CODE tracks the worst status seen so far in the CALLING
# script via log_warn/log_fail below, so a script can just do
# `exit "$SYS_EXIT_CODE"` at the very end instead of tracking this
# itself in every check.
SYS_EXIT_CODE=0

# Only emit ANSI color codes when stdout is an actual terminal -
# keeps cron mail / log files / `| cat` output free of escape junk.
if [[ -t 1 ]]; then
    _SYS_C_OK=$'\033[32m'      # green
    _SYS_C_WARN=$'\033[33m'    # yellow
    _SYS_C_FAIL=$'\033[31m'    # red
    _SYS_C_INFO=$'\033[36m'    # cyan
    _SYS_C_RESET=$'\033[0m'
else
    _SYS_C_OK=""; _SYS_C_WARN=""; _SYS_C_FAIL=""; _SYS_C_INFO=""; _SYS_C_RESET=""
fi

# log_ok/log_warn/log_fail/log_info <message>
# Print a status-tagged line. log_warn/log_fail also raise
# SYS_EXIT_CODE so the calling script's final exit code reflects
# the worst thing it saw, without every script re-implementing that
# bookkeeping by hand.
log_ok()   { printf '%s[ OK ]%s %s\n'   "$_SYS_C_OK"   "$_SYS_C_RESET" "$1"; }
log_info() { printf '%s[INFO]%s %s\n'   "$_SYS_C_INFO" "$_SYS_C_RESET" "$1"; }
log_warn() {
    printf '%s[WARN]%s %s\n' "$_SYS_C_WARN" "$_SYS_C_RESET" "$1"
    # NOTE: must be a plain `if`, not `(( cond )) && assign` - under
    # `set -e`, that idiom's overall exit status is FALSE (1) on every
    # call after the first time SYS_EXIT_CODE reaches 1, which aborts
    # the calling script right here, silently skipping everything
    # after it (found by testing: the final summary/sys_log/exit
    # lines in every script were being skipped whenever log_warn ran
    # a second time).
    if (( SYS_EXIT_CODE < 1 )); then
        SYS_EXIT_CODE=1
    fi
}
log_fail() {
    printf '%s[FAIL]%s %s\n' "$_SYS_C_FAIL" "$_SYS_C_RESET" "$1"
    SYS_EXIT_CODE=2
}

# have_cmd <name> - true if <name> is on PATH.
# Thin wrapper kept mainly so call sites read as intent ("have_cmd
# smartctl") rather than the more cryptic "command -v smartctl >/dev/null".
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# require_root <what-for> - exit 2 with a clear message unless EUID==0.
# Used by steps that would otherwise fail confusingly deep inside a
# command (e.g. "Permission denied" from sv or iptables) instead of
# with a clear explanation up front.
require_root() {
    if (( EUID != 0 )); then
        log_fail "$1 requires root - re-run this script with sudo."
        exit 2
    fi
}

# sys_log <script-name> <message> - append a timestamped line to
# ~/.local/state/system-scripts/<script-name>.log (XDG state dir),
# creating the directory on first use. This gives a persistent audit
# trail of what these scripts have done over time without needing
# root-only syslog access (see socklog permissions note in the plan).
sys_log() {
    local name="$1" message="$2"
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/system-scripts"
    mkdir -p "$state_dir"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "${state_dir}/${name}.log"
}
