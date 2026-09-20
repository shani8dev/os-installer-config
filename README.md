# os-installer-config

Distro-specific configuration for GNOME's
[os-installer](https://gitlab.gnome.org/p3732/os-installer) — the GTK4/
libadwaita installer framework Shanios ships (built via the
[os-installer-git](https://github.com/shani8dev/shani-pkgbuilds/tree/main/os-installer-git)
PKGBUILD, which patches upstream for Shanios-specific needs). This repo is
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
- **`user.min_password_length: 1`** — deliberately unenforced; Shanios
  doesn't gate on password strength at install time. (Also governs the
  root-password field added by the `add-root-password.patch` in
  os-installer-git, which mirrors this same setting for consistency.)
- **`internet`** — `connection_required: no` disables the network check so
  offline installs work; `checker_url` sets the probe URL when a check is
  needed.
- **`welcome_page`** — `logo` points to the Shanios logo, `text` is the
  markdown shown on the welcome screen, and `usage: yes` enables the page.
- **`disk.min_size: 28`** — minimum target disk size in GiB, set to match
  actual usable space on Shanios's 32GB cards.
- **`commands`** — overrides the external programs the installer calls:
  `browser` (default `firefox`), `disks` (`gnome-disks`), `reboot`
  (`shutdown -r now`), and `wifi` (`gnome-control-center wifi`).

Any config key not listed here that's actually read by the installer keeps
upstream's default — see os-installer's own `src/core/config.py` for the
full set.

## `scripts/`

Run in order by os-installer, each receiving `OSI_*` environment variables
(installer state — chosen disk, encryption PIN, generated username, etc.)
that this repo's scripts consume:

- **`prepare.sh`** — runs early, while the user is still on the welcome/
  disk pages. Only checks the invoking user is in `wheel`/`sudo`.
- **`install.sh`** — disk partitioning and filesystem layout. Partitions
  the target disk per `bits/part.sfdisk` (a 2-partition GPT layout: a 1GiB
  FAT32 ESP, then a Btrfs root taking the rest), sets up LUKS if requested,
  creates the Btrfs subvolume structure, and extracts the root image as
  `@blue`/`@green`-ready snapshots for the blue-green deployment model
  `shani-deploy` uses post-install, plus dedicated `@flatpak` and `@snapd`
  subvolumes for flatpak/snap data.
- **`configure.sh`** — the largest script: hostname, machine-id, keyboard
  layout (parses `OSI_KEYBOARD_LAYOUT` into vconsole + X11 keymap fields),
  locale/timezone/user account setup (all currently unreachable given
  `skip_region`/`skip_user` above, but kept correct for any profile that
  re-enables them), root password, Plymouth theme, firewall rules,
  Secure Boot MOK key generation and enrollment, LUKS crypttab, and the
  initial UKI + boot entry generation for the freshly-installed slot.
**MOK enrollment password** — `configure.sh` stages Secure Boot MOK
enrollment with the well-known literal `shanios`. It has to be a literal
the user can know ahead of time: MokManager prompts for the confirmation
password on first boot, so it can't be random-per-install. The literal
itself is unchanged from the original; what was fixed is that an earlier
version logged it in plaintext via `log_info`, so anyone reading the
installer log learned every machine's enrollment password. It is no
longer logged.

Every `run_in_target()` call (the helper that runs a command inside the
chroot'd target system) passes installer-provided values — usernames,
keyboard layouts, locale strings — as real positional arguments rather
than interpolating them into the command string, specifically so a value
containing a shell metacharacter can't break out and run arbitrary code
inside the chroot.

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
