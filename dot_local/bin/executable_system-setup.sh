#!/usr/bin/env bash
#
# system-setup.sh - bootstrap this machine from a fresh Void install
# back up to its current state: packages, repos, services, minimal
# system config, and finally the chezmoi-managed dotfiles.
#
# This is the "how do I get from a blank Void ISO back to this exact
# machine" script. Unlike its siblings (which assume an already-set-up
# system and just maintain it), this one does the initial provisioning
# - but it's still idempotent, so re-running it on an already-set-up
# machine is safe and mostly a no-op.
#
# Ordering matters and is NOT arbitrary:
#   1-3 (base upgrade, repos, packages) are hard prerequisites - if
#       any of these fail the script stops immediately, since nothing
#       after them can succeed meaningfully on top of a broken base.
#   4-10 degrade gracefully - each step logs a WARN/FAIL and moves on,
#       since they're mostly independent of each other.
#   The chezmoi clone happens BEFORE the GRUB/ly restore (steps 9-10
#   read backup copies of those files out of the chezmoi repo itself),
#   but the actual `chezmoi apply` - "install the chezmoi
#   configuration" - is deliberately the LAST thing this script does.
#
# Usage: system-setup.sh [-y|--yes] [-h|--help]
#   -y, --yes   don't prompt for confirmation before starting
#               (needed for unattended use)
#   -h, --help  show this help and exit
#
# Exit codes: 0 = completed with nothing to flag
#             1 = completed, but see the WARN lines above (usually
#                 "reboot to see this take effect")
#             2 = a step failed
#
# ============================================================

# -e: stop on the first unhandled error - a half-provisioned machine
#     from a script that silently ploughed through failures is worse
#     than one that stops and tells you exactly where it broke.
# -u: catch typos in variable names instead of silently expanding
#     them to empty strings (dangerous here: several steps below
#     build sudo/xbps commands from variables).
# -o pipefail: a failure in the middle of a pipeline should still
#     fail the script, not get masked by the last command in the pipe
#     succeeding.
set -euo pipefail

script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=system-lib.sh
source "${script_dir}/system-lib.sh"

# --- must run as the normal user, not root ---
#
# The opposite problem from system-lib.sh's require_root(): this
# script needs to run AS the target user, because the final chezmoi
# apply, the crontab edit, and the group/hostname changes all need to
# resolve "you" correctly. Individual steps that need elevation call
# `sudo` themselves instead.
if (( EUID == 0 )); then
    log_fail "Run this as your normal user, not root - it uses sudo for the steps that need elevation, and needs to know who 'you' are for chezmoi/crontab/groups."
    exit 2
fi

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

if (( assume_yes == 0 )); then
    cat <<'EOF'
This will, on this machine:
  - sync repodata and upgrade the base xbps system
  - add the black-hole.dev third-party repo + void-repo-nonfree
  - install the ~99 packages this machine already has
  - enable ~22 runit services
  - set locale/keymap/hostname, add supplementary groups, add a cron entry
  - restore the GRUB boot theme and ly login theme (both root-owned,
    not managed by chezmoi)
  - clone/apply the avalon-amber chezmoi dotfiles from GitHub

All of the above is idempotent - safe to re-run on a machine that's
already (partly) set up. Nothing here touches SSH keys, rbw/Bitwarden,
or gh auth - those stay manual (see the summary printed at the end).
EOF
    # `read` exits non-zero on EOF (e.g. stdin isn't a terminal) -
    # `|| reply=""` treats that the same as a plain "no" instead of
    # letting `set -e` kill the script mid-message.
    read -r -p "Proceed? [y/N] " reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        log_warn "setup cancelled by user."
        exit 1
    fi
fi

if [[ -r /etc/os-release ]] && ! grep -q '^ID=void' /etc/os-release; then
    log_warn "This doesn't look like Void Linux (/etc/os-release has no ID=void) - continuing anyway, but the xbps-specific steps below will likely fail."
fi

# Prime the sudo credential cache once up front so the many sudo calls
# below don't repeatedly prompt (ticket lasts ~15 min by default,
# comfortably longer than a normal run of this script).
log_info "Priming sudo credential cache (you may be prompted once)..."
sudo -v

# --- 1. base system upgrade ---
#
# Standard Void fresh-install practice: bring the base system current
# before layering the rest on top of it. If this fails, stop here -
# installing 99 more packages on top of a broken/stale base is asking
# for trouble.
log_info "-- base system upgrade --"
if sudo xbps-install -Syu; then
    log_ok "base system is up to date."
else
    log_fail "base system upgrade failed - aborting before installing anything on top of it."
    exit 2
fi

# --- 2. third-party repo + nonfree repo ---
log_info "-- third-party repo: black-hole.dev --"
# NOT part of official Void repos - this machine's actual hyprland,
# hyprlock, hypridle, and ly come from here instead, because upstream
# Hyprland moves faster than Void's main repo tracks. Must exist
# before the big package install below, or those four installs fail.
blackhole_conf=/etc/xbps.d/10-repository-blackhole.conf
blackhole_line="repository=https://mirror.black-hole.dev/x86_64/"
if [[ -f "$blackhole_conf" ]] && grep -qxF "$blackhole_line" "$blackhole_conf"; then
    log_ok "black-hole.dev repo already configured."
else
    printf '%s\n' "$blackhole_line" | sudo tee "$blackhole_conf" >/dev/null
    log_ok "black-hole.dev repo configured."
fi

log_info "-- nonfree repo (intel-ucode, mesa-vulkan-intel, intel-video-accel) --"
# void-repo-nonfree is itself one of the packages in the big list
# below, but it only takes effect once installed AND repodata is
# re-synced - installing it in the same transaction as everything
# that depends on it doesn't work, since xbps reads the repo list
# once at the start of a transaction. So: install it alone first,
# then do the real -Sy pass with the full list next.
if xbps-query -m 2>/dev/null | grep -q '^void-repo-nonfree-'; then
    log_ok "void-repo-nonfree already installed."
else
    if sudo xbps-install -Sy void-repo-nonfree; then
        log_ok "void-repo-nonfree installed."
    else
        log_fail "installing void-repo-nonfree failed - aborting."
        exit 2
    fi
fi

# --- 3. full package set ---
#
# Every package this machine has EXPLICITLY installed (`xbps-query -m`),
# captured live and hand-verified against this machine on 2026-08-12.
# Everything else "ii" on this machine is an automatically-pulled
# dependency - xbps resolves those on its own from each package's
# declared deps, same as it always has, no need to list them here.
packages=(
    ImageMagick NetworkManager Waybar alsa-utils avahi banner base-devel
    base-system bat bluetuith bluez brightnessctl chezmoi chromium chrony
    cliphist cmake cowsay cups cups-filters cups-pdf dbus dcron difftastic
    direnv dtrx dunst elogind fastfetch figlet figlet-fonts flatpak
    font-unifont-bdf git github-cli grim grub-utils grub-x86_64-efi helix
    htop hypridle hyprland hyprland-guiutils hyprlock inetutils intel-ucode
    intel-video-accel jq kitty lm_sensors ly mesa-dri mesa-vulkan-intel
    meson mosh ncspot nodejs noto-fonts-cjk noto-fonts-emoji noto-fonts-ttf
    noto-fonts-ttf-extra pipewire pkg-config podman polkit polkit-gnome
    python python3-adblock qt6-wayland qt6ct qutebrowser rbw rsync seatd
    slurp smartmontools socklog-void starship swaybg tlp tree
    void-repo-nonfree vulkan-loader w3m wev wget wireless-regdb wireplumber
    wl-clipboard wlogout wofi xdg-desktop-portal-gtk
    xdg-desktop-portal-hyprland xtools yazi zellij zsh zsh-autosuggestions
    zsh-syntax-highlighting
)

log_info "-- installing/confirming ${#packages[@]} packages --"
if sudo xbps-install -Sy "${packages[@]}"; then
    log_ok "package set installed/confirmed."
else
    log_fail "package install failed - see xbps-install output above - aborting."
    exit 2
fi

# --- 4. runit services ---
#
# None of these auto-enable from package installation alone on Void -
# each needs an explicit symlink into /var/service. `ln -sf` is a
# no-op if it's already correct, so this loop is safe to re-run.
log_info "-- runit services --"
services=(
    NetworkManager acpid agetty-tty1 agetty-tty3 agetty-tty4 agetty-tty5
    agetty-tty6 avahi-daemon bluetoothd chronyd cupsd dbus dcron dhcpcd
    elogind ip6tables iptables ly nanoklogd socklog-unix tlp udevd
)
for svc in "${services[@]}"; do
    if [[ -L "/var/service/$svc" && "$(readlink -f "/var/service/$svc")" == "/etc/sv/$svc" ]]; then
        log_ok "service already enabled: $svc"
    elif [[ ! -d "/etc/sv/$svc" ]]; then
        log_warn "service definition /etc/sv/$svc doesn't exist - skipping (its package may not be installed)."
    else
        sudo ln -sf "/etc/sv/$svc" /var/service/
        log_ok "service enabled: $svc"
    fi
done

# --- 5. locale, keymap, hostname ---
log_info "-- locale, keymap, hostname --"

hostname_target="into-the-void"   # this machine's identity - edit if reusing this script elsewhere

# fr_CH.UTF-8 has to be uncommented in /etc/default/libc-locales
# before glibc-locales will actually generate it - a fresh Void
# install ships this commented out.
libc_locales=/etc/default/libc-locales
if grep -qx "fr_CH.UTF-8 UTF-8" "$libc_locales" 2>/dev/null; then
    log_ok "fr_CH.UTF-8 already enabled in $libc_locales."
else
    if grep -q "^#fr_CH\.UTF-8 UTF-8" "$libc_locales" 2>/dev/null; then
        sudo sed -i 's/^#fr_CH\.UTF-8 UTF-8/fr_CH.UTF-8 UTF-8/' "$libc_locales"
    else
        # Not present at all (even commented) - append it rather than
        # silently doing nothing.
        printf 'fr_CH.UTF-8 UTF-8\n' | sudo tee -a "$libc_locales" >/dev/null
    fi
    log_ok "enabled fr_CH.UTF-8 in $libc_locales."
    sudo xbps-reconfigure -f glibc-locales
fi

sudo tee /etc/locale.conf >/dev/null <<'EOF'
LANG=fr_CH.UTF-8
LC_COLLATE=C
EOF
log_ok "/etc/locale.conf written."

if grep -qx "KEYMAP=fr_CH" /etc/rc.conf 2>/dev/null; then
    log_ok "KEYMAP already set to fr_CH in /etc/rc.conf."
elif grep -q "^#\{0,1\}KEYMAP=" /etc/rc.conf 2>/dev/null; then
    sudo sed -i 's/^#\{0,1\}KEYMAP=.*/KEYMAP=fr_CH/' /etc/rc.conf
    log_ok "KEYMAP set to fr_CH in /etc/rc.conf."
else
    printf '\nKEYMAP=fr_CH\n' | sudo tee -a /etc/rc.conf >/dev/null
    log_ok "KEYMAP appended to /etc/rc.conf."
fi

if [[ "$(cat /etc/hostname 2>/dev/null)" == "$hostname_target" ]]; then
    log_ok "hostname already set to $hostname_target."
else
    printf '%s\n' "$hostname_target" | sudo tee /etc/hostname >/dev/null
    sudo hostname "$hostname_target"
    log_ok "hostname set to $hostname_target."
fi

# --- 6. supplementary groups ---
log_info "-- supplementary groups --"
target_groups="wheel,audio,video,cdrom,optical,kvm,floppy,xbuilder,lpadmin,_seatd"
if sudo usermod -aG "$target_groups" "$(id -un)"; then
    log_ok "group membership ensured: $target_groups"
    log_warn "group changes only take effect on next login - log out/in (or reboot) to pick them up."
else
    log_fail "usermod failed to set supplementary groups."
fi

# --- 7. cron: weekly periodic maintenance ---
log_info "-- cron: weekly periodic maintenance --"
cron_line="0 4 * * 0 ${HOME}/.local/bin/system-periodic-maintenance.sh -y"
if crontab -l 2>/dev/null | grep -qxF "$cron_line"; then
    log_ok "weekly maintenance cron entry already present."
else
    { crontab -l 2>/dev/null || true; printf '%s\n' "$cron_line"; } | crontab -
    log_ok "weekly maintenance cron entry added."
fi

# --- 8. chezmoi: clone (not applied yet) ---
#
# Cloning here (rather than at the very end) is what makes the
# root-overlay/ backup below available locally for steps 9-10. The
# actual dotfile *application* - "install the chezmoi configuration"
# - stays the last thing this script does, per how this was asked for.
log_info "-- chezmoi: cloning avalon-amber --"
chezmoi_source_dir="${HOME}/.local/share/chezmoi"
chezmoi_freshly_cloned=0
if [[ -d "${chezmoi_source_dir}/.git" ]]; then
    log_ok "chezmoi source dir already exists at ${chezmoi_source_dir} - skipping clone."
else
    if chezmoi init marc-0x01/avalon-amber; then
        log_ok "cloned avalon-amber into ${chezmoi_source_dir}."
        chezmoi_freshly_cloned=1
    else
        log_fail "chezmoi init failed - can't proceed with the GRUB/ly restore or the final apply - aborting."
        exit 2
    fi
fi

overlay_dir="$(chezmoi source-path)/root-overlay"

# --- 9. GRUB theme restore ---
#
# Root-owned, lives outside $HOME entirely, so chezmoi itself can't
# manage it - it's backed up as a plain file tree under root-overlay/
# in the same repo (ignored by `chezmoi apply` via .chezmoiignore) and
# restored here by hand.
log_info "-- GRUB theme restore --"
if [[ -d "${overlay_dir}/boot/grub/themes/avalon-amber" ]]; then
    sudo install -D -m 0644 "${overlay_dir}/boot/grub/themes/avalon-amber/theme.txt" /boot/grub/themes/avalon-amber/theme.txt
    sudo install -D -m 0644 "${overlay_dir}/boot/grub/themes/avalon-amber/background.png" /boot/grub/themes/avalon-amber/background.png
    sudo install -D -m 0644 "${overlay_dir}/boot/grub/themes/avalon-amber/skull.png" /boot/grub/themes/avalon-amber/skull.png
    sudo install -D -m 0644 "${overlay_dir}/boot/grub/themes/avalon-amber/avalon_amber_16.pf2" /boot/grub/themes/avalon-amber/avalon_amber_16.pf2
    sudo install -D -m 0644 "${overlay_dir}/etc/default/grub" /etc/default/grub
    log_ok "GRUB theme files + /etc/default/grub restored."

    if have_cmd grub-mkconfig; then
        if sudo grub-mkconfig -o /boot/grub/grub.cfg; then
            log_ok "grub.cfg regenerated."
            log_warn "reboot to actually see the new GRUB theme."
        else
            log_fail "grub-mkconfig failed - theme files are in place but grub.cfg wasn't regenerated."
        fi
    else
        log_warn "grub-mkconfig not found (grub-utils not installed?) - theme files copied but grub.cfg NOT regenerated."
    fi
else
    log_warn "no GRUB theme found under ${overlay_dir} - skipping (repo may be out of sync with this script)."
fi

# --- 10. ly login theme restore ---
log_info "-- ly login theme restore --"
if [[ -f "${overlay_dir}/etc/ly/config.ini" ]]; then
    sudo install -D -m 0644 "${overlay_dir}/etc/ly/config.ini" /etc/ly/config.ini
    log_ok "ly config.ini restored."
    # Deliberately NOT auto-restarting ly here: if this script is
    # running from inside a session ly itself spawned, `sv restart ly`
    # could kill that session out from under the person running it.
    log_warn "ly won't pick this up until it restarts - reboot, or run 'sudo sv restart ly' from a DIFFERENT session/tty."
else
    log_warn "no ly config found under ${overlay_dir} - skipping."
fi

# --- 11. chezmoi: apply ---
log_info "-- chezmoi: applying dotfiles --"
if (( chezmoi_freshly_cloned == 1 )); then
    if chezmoi apply; then
        log_ok "chezmoi apply completed."
    else
        log_fail "chezmoi apply failed - see output above."
    fi
else
    log_info "source dir pre-existed - pulling latest and applying (chezmoi update) instead of a fresh apply."
    if chezmoi update; then
        log_ok "chezmoi update completed."
    else
        log_fail "chezmoi update failed - see output above."
    fi
fi

# --- summary ---
echo
case "$SYS_EXIT_CODE" in
    0) log_ok "system-setup complete - nothing to flag." ;;
    1) log_warn "system-setup complete - see the WARN lines above (usually just 'reboot to see this take effect')." ;;
    *) log_fail "system-setup complete - see the FAIL lines above." ;;
esac

cat <<'EOF'

Not handled by this script - do these manually:
  - SSH commit-signing key: generate ~/.ssh/id_ed25519, upload the
    public key to GitHub as a Signing Key, and populate
    ~/.ssh/allowed_signers (dot_gitconfig already expects these -
    commits will fail to sign until this is done).
  - rbw / Bitwarden: run `rbw login` then `rbw unlock`.
  - GitHub CLI auth: run `gh auth login`.
EOF

sys_log setup "exit=$SYS_EXIT_CODE hostname=$hostname_target euid=$EUID"
exit "$SYS_EXIT_CODE"
