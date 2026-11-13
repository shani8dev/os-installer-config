# os-installer-config

Distro-specific configuration for the
[ShaniOS Installer](https://github.com/shani8dev/os-installer) — our fork of
GNOME's os-installer, the GTK4/libadwaita installer framework Shanios ships
(built via the
[os-installer-git](https://github.com/shani8dev/shani-pkgbuilds/tree/main/os-installer-git)
PKGBUILD, which builds the fork directly — no patch stack). This repo is
installed to `/etc/os-installer/` and drives what the installer UI shows,
what happens when a user actually confirms an install, and what the
resulting system looks like on first boot.

## `config.yaml`

The installer reads this at startup to decide which pages to show and how
they behave. Notable Shanios-specific choices, and why:

- **`fixed_language: en_US`** — skips the language-selection page entirely;
  Shanios ships one language per install rather than offering a picker.
- **`skip_region: yes`, `skip_user: yes`** — skip the region (locale/
  timezone/keyboard formats) and user-account pages. Both are deferred to
  **gnome-initial-setup** on first boot instead — `shani-user-setup`
  (in [shani-deploy](https://github.com/shani8dev/shani-deploy)) then syncs
  the resulting account into Shanios's extra groups.
- **`disk.partition_ok: no`** — only whole-disk installs are offered, never
  an existing partition. Each desktop edition (GNOME/Plasma/COSMIC) ships
  as its own ISO, so there's no in-installer "choose your desktop" step
  either — `desktop` is never set in this file.
- **`disk_encryption`** — LUKS is offered but not forced, with PIN
  confirmation required.
- **`secure_boot`** — not set, so `offered: auto`: the Secure Boot page
  appears only on UEFI. It stages MOK enrollment and takes the one-time
  MokManager password (a separate one, or the root password via
  `mokutil --root-pw`; `mok_password_min_length` is the minimum for the
  separate one).
- **`tpm`** — not set, so `offered: auto`: the TPM page appears only when a
  TPM is present. It records that the encrypted disk should unlock with the
  TPM; enrollment itself is done after first boot with
  `gen-efi.sh enroll-tpm2` (the installer cannot seal against the installed
  system's final PCRs).
- **`install_policy`** — not set, so the installer's defaults are used: the
  ShaniOS labels, btrfs subvolume list, image directory, swapfile path and
  boot-entry paths. Set a key here only to override one.
- **`user.min_password_length: 1`** — deliberately unenforced; Shanios
  doesn't gate on password strength at install time. (Also governs the
  root-password field the ShaniOS fork adds, which mirrors this same setting
  for consistency, and is exported as `OSI_MIN_PASSWORD_LENGTH`.)
- **`internet`** — `connection_required: no` disables the network check so
  offline installs work; `checker_url` sets the probe URL when a check is
  needed.
- **`welcome_page`** — `logo` points to the Shanios logo, `text` is the
  markdown shown on the welcome screen, and `usage: yes` enables the page.
- **`disk.min_size: 30`** — minimum target disk size in GB, set to match
  actual usable space on Shanios's 32GB cards.

Any config key not listed here that's actually read by the installer keeps
upstream's default — see os-installer's own `src/core/config.py` for the
full set.

## `scripts/`

Run in order by os-installer, each receiving `OSI_*` environment variables
(installer state — chosen disk, encryption PIN, generated username, etc.)
that this repo's scripts consume:

- **`prepare.sh`** — runs early, while the user is still on the welcome/
  disk pages. Checks the invoking user is in `wheel`/`sudo` (the installer
  checks this too, before starting the first script, so a direct run stays
  safe).
- **`install.sh`** — disk partitioning and filesystem layout. Partitions
  the target disk per `bits/part.sfdisk` (a 2-partition GPT layout: a 1GiB
  FAT32 ESP, then a Btrfs root taking the rest), sets up LUKS if requested,
  creates the Btrfs subvolume structure, and extracts the root image as
  `@blue`/`@green`-ready snapshots for the blue-green deployment model
  `shani-deploy` uses post-install, plus dedicated `@flatpak` and `@snapd`
  subvolumes for flatpak/snap data. Labels, the subvolume list, the image
  directory and image names, the swapfile path and the partition layout come
  from the installer (`OSI_ROOT_LABEL`, `OSI_BTRFS_SUBVOLUMES`,
  `OSI_IMAGE_DIR`, …, with the old literals as fallbacks).
- **`configure.sh`** — the largest script: hostname, machine-id, keyboard
  layout (parses `OSI_KEYBOARD_LAYOUT` into vconsole + X11 keymap fields),
  locale/timezone/user account setup (all currently unreachable given
  `skip_region`/`skip_user` above, but kept correct for any profile that
  re-enables them), root password, Plymouth theme, firewall rules,
  Secure Boot MOK key generation and enrollment, LUKS crypttab, and the
  initial UKI + boot entry generation for the freshly-installed slot.
  `skip_user`/`skip_region` come from the installer as `OSI_SKIP_*`; the
  kernel cmdline files and UKI entry directory come from
  `OSI_KERNEL_CMDLINE_*` / `OSI_UKI_BOOT_ENTRIES`.
- **`repair.sh`** — `--repair`: no partitioning or extraction. Finds the active slot from `@data/current-slot`, runs `configure.sh` on the existing system, then `gen-efi configure <slot>` and `enroll-mok`. Keeps the machine-id and an existing user.
- **`validate-config.sh`** — checks the YAML, the referenced scripts and the
  top-level keys against the installer's own config schema.

**MOK enrollment password** — two modes, chosen on the installer's Secure
Boot page. Either the user types a one-time password (minimum length from
`secure_boot.mok_password_min_length`, exported as `OSI_MOK_PASSWORD`), or
the installer uses the root password with `mokutil --root-pw` (exported as
`OSI_MOK_ROOT_PW=1`; mokutil reads the hash from the target's `/etc/shadow`,
so a root password must be set). Either way MokManager asks for it once on
the next boot, and it is never stored on the installed system. The literal
`shanios` remains the fallback for a direct, non-installer run.

**TPM** — the installer's TPM page exports `OSI_USE_TPM=1` when the user
wants the encrypted disk to unlock with the TPM. `configure.sh` enrolls it
during installation: the target's LUKS mapper is open, and it uses the same
literal PCR policy `gen-efi` uses on a booted system (0+7 with Secure Boot,
0 without), with `OSI_ENCRYPTION_PIN` as the passphrase. The PIN slot stays,
so a failed auto-unlock never locks the user out. A pcrlock policy is left to
`gen-efi.sh enroll-tpm2` after first boot, because it needs the booted
initramfs.

Every `run_in_target()` call (the helper that runs a command inside the
chroot'd target system) passes installer-provided values — usernames,
keyboard layouts, locale strings — as real positional arguments rather
than interpolating them into the command string, specifically so a value
containing a shell metacharacter can't break out and run arbitrary code
inside the chroot.

## What the installer hands over (`OSI_*`)

Beyond the choices the pages collect, the installer exports its install policy
(`install_policy`) and the security choices, so the scripts do not hardcode
them. Every value has a fallback in the scripts, so an older installer still
works.

| Variable | From | Used by |
|---|---|---|
| `OSI_OS_NAME`, `OSI_ROOT_LABEL`, `OSI_BOOT_LABEL` | `install_policy` | install, configure |
| `OSI_PARTITION_LAYOUT`, `OSI_BTRFS_SUBVOLUMES`, `OSI_BTRFS_TOP_OPTS`, `OSI_SWAPFILE_PATH` | `install_policy` | install |
| `OSI_IMAGE_DIR`, `OSI_ROOTFS_IMAGE`, `OSI_FLATPAK_IMAGE`, `OSI_SNAP_IMAGE`, `OSI_AI_MODELS_IMAGE` | `install_policy` | install |
| `OSI_KERNEL_CMDLINE_CURRENT/_CANDIDATE`, `OSI_UKI_BOOT_ENTRIES` | `install_policy` | configure |
| `OSI_SKIP_USER`, `OSI_SKIP_REGION` | `skip_user`, `skip_region` | configure |
| `OSI_MIN_PASSWORD_LENGTH`, `OSI_USER_GROUPS` | `user` | configure |
| `OSI_HOSTNAME` | `hostname` (or the hostname page) | configure |
| `OSI_MOK_ENROLL`, `OSI_MOK_PASSWORD`, `OSI_MOK_ROOT_PW` | Secure Boot page | configure |
| `OSI_USE_TPM`, `OSI_USE_TPM_PIN`, `OSI_TPM_PIN` | TPM page | configure |
| `OSI_RECOVERY_KEY` | generated by the installer | configure |
| `OSI_DISK_ERASE` | `disk_erase` | install |
| `OSI_TIME_SYNC`, `OSI_COPY_NETWORK` | config | configure |

`configure.sh` writes the recovery key to `/run/os-installer/recovery-key`
(mode 644) after adding the keyslot; the installer shows it once on the done
page, and `/run` is a tmpfs, so a reboot removes it.

## Known gaps & design rules

**Failure-safety invariants (don't reintroduce):**
- Every successful mount and LUKS open pushes an undo command
  (`mount_tracked()`/`_push_cleanup`) onto a chronological stack; `die()`
  and the `ERR` trap both unwind that stack in reverse (LIFO — children
  before parents, mapper closed only after whatever was mounted on top of
  it is gone) before exiting. A normal successful exit never triggers this
  — both scripts intentionally leave the target mounted for the next stage.
- EFI signing must verify the signed output *before* it replaces the live
  file, never after — the live binary must never be observed in a
  signed-but-invalid state.
- Any secret-handling change (LUKS passphrase, user password, MOK
  enrollment password) must be run through the `ps -eo pid,args` /
  `/proc/*/cmdline` polling pattern concurrently with a real test-harness
  run; this exact class of bug (argv leak, positional-argument leak via
  `chroot ... bash -c`) has been found here before.

**Open, not yet independently verified:**
- `sign_efi_binary()`'s verify-before-replace ordering is verified only
  for the happy path and the "already signed" fast path. A forced
  signing-failure path (stub `sbsign` to succeed while producing garbage)
  has not been re-run since the fix — the ordering fix is correct by
  construction, but the negative control was not re-executed.

**Cross-repo impact:**
- These scripts are consumed and tested by `shani-install-media`
  (`build.sh test install`/`configure`) and packaged by a PKGBUILD in
  `shani-pkgbuilds` (`os-installer`/`os-installer-git`). A change to an
  `OSI_*` variable's meaning, a new required variable, or a changed exit
  code needs the test harness in `shani-install-media` updated to match,
  and the packaging in `shani-pkgbuilds` checked for anything it assumes
  about this repo's layout.

## `bits/part.sfdisk`

The `sfdisk` script defining the whole-disk partition layout: a 1GiB EFI
System Partition (FAT32, label `shani_boot`), then a Btrfs root partition
(label `shani_root`) using the Discoverable Partitions Specification type,
taking all remaining space.

## `icons/`, `po/`

UI icons the installer references, and gettext translation files
(`config.pot`/`*.po`) for any user-facing strings this repo's `config.yaml`
itself contributes (e.g. the welcome page's custom text) — separate from
os-installer's own upstream translations.
