#!/bin/bash
# repair.sh — repair an existing ShaniOS installation.
#
# Re-runs the installer's configuration and the boot chain on a system that is
# already installed: no partitioning, no mkfs, no image extraction. Use it for
# a broken boot entry, a missing/incorrect locale or account, a stale MOK
# signature or a UKI that no longer boots.
#
#   OSI_REPAIR=1   set by the installer's --repair (install.sh execs this)
#   OSI_DRY_RUN=1  print the steps instead of running them
#
# It mounts only to find the active slot; configure.sh does the real mounting
# (mount_target) and the system-side work, exactly as it does after an install.
#
# Verify on a real machine (shani-testbed `iso-install`) before trusting it.
set -Eeuo pipefail

ROOTLABEL="${OSI_ROOT_LABEL:-shani_root}"
OSIDIR="${OSIDIR:-/etc/os-installer}"
DRY="${OSI_DRY_RUN:-0}"

log()  { echo "[REPAIR] $*"; }
warn() { echo "[REPAIR][WARN] $*" >&2; }
die()  { echo "[REPAIR][ERROR] $*" >&2; exit 1; }
run()  { if [[ "${DRY}" == "1" ]]; then echo "[DRY] $*"; else "$@"; fi; }

[[ ${EUID} -eq 0 ]] || die "must run as root"

mapper="/dev/disk/by-label/${ROOTLABEL}"
[[ -b "${mapper}" ]] || mapper="/dev/mapper/${ROOTLABEL}"
[[ -b "${mapper}" ]] || die "no ${ROOTLABEL} device found — is the disk attached (and unlocked)?"

# Find the active slot: /data/current-slot lives on @data, inside the root btrfs.
tmp=$(mktemp -d)
run mount -o subvolid=5 "${mapper}" "${tmp}"
slot=$(cat "${tmp}/@data/current-slot" 2>/dev/null || true)
run umount "${tmp}"
rmdir "${tmp}"
[[ "${slot}" == "blue" || "${slot}" == "green" ]] || slot=blue
log "active slot: ${slot}"

# configure.sh mounts the target itself (mount_target) and does the work.
run env OSI_REPAIR=1 /bin/bash "${OSIDIR}/scripts/configure.sh"

# The boot chain: re-sign/reinstall the UKI and bootloader, then stage MOK.
if [[ -x /usr/bin/gen-efi.sh ]]; then
    run /usr/bin/gen-efi.sh configure "${slot}" || warn "gen-efi configure failed"
    run /usr/bin/gen-efi.sh enroll-mok || warn "MOK enrollment staging failed"
else
    warn "gen-efi.sh not found — the UKI and MOK were not refreshed"
fi

log "repair finished (slot ${slot})"