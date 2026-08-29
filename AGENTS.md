# Agent instructions — os-installer-config

This file applies to any AI coding assistant working in this repository
(Claude Code, opencode, Kilo Code, Cursor, Aider, or similar). Read this
before editing, and follow the verification steps before calling any change
done.

## What this repo is

Distro-specific configuration for GNOME's `os-installer` — the GTK4/
libadwaita installer framework Shanios ships. `install.sh` partitions and
formats a real disk; `configure.sh` runs once, as root, inside the newly
installed system. There is no "undo" for a bad partition table or a
half-configured install — verify accordingly, not like ordinary
application code.

## Rule: these scripts run once, as root, during a real OS install — verify accordingly

`install.sh` partitions and formats a real disk; `configure.sh` runs
inside the freshly installed chroot setting locale/hostname/users/
Secure-Boot enrollment. A bug here doesn't fail gracefully — it can leave
an unbootable or insecurely-configured system. Both scripts are fully
driven by `OSI_*` environment variables (no GUI required to run them), so
there's no excuse for verifying a change by source review alone — actually
run it.

## If you have Superpowers / oh-my-opencode / ultrawork / similar available

If your environment provides Claude Code's **Superpowers** plugin (TDD,
debugging, and verification-discipline skills), OpenCode's
**oh-my-opencode** (parallel/async subagents, LSP/AST tooling), an
**ultrawork**-style high-autonomy parallel execution mode, or an
equivalent skill/subagent framework in whatever tool you're running as —
use its parallel-subagent capability specifically for the
before/after comparison pattern below (one agent proving the old pattern
leaks or breaks, another proving the fix doesn't) and for running the
`ps aux` monitoring loop concurrently with the actual install/configure
run. Don't let a skill framework's plan-and-report output substitute for
actually executing these scripts.

## Required verification for any change

Use the sibling `shani-install-media` repo's test harness rather than
building scratch disk images by hand each time:

```bash
cd ../shani-install-media
./run_in_container.sh build.sh test install [--encrypted]
./run_in_container.sh build.sh test configure
```

Or in one step — `./run_in_container.sh build.sh test bootstrap -p <profile>
-d latest [--encrypted]` runs both of the above back-to-back (plus one
test-only step unrelated to this repo: trust-anchoring a throwaway CA into
the result) and is what most other repos' own test cycles (`shani-deploy`,
image-profile changes) build on top of — so a change here that breaks
`bootstrap` breaks their verification too, not just this repo's own.
`run_in_container.sh` always bind-mounts *this* checkout read-only at
`/opt/os-installer-config` inside the container (a no-op if it isn't found
as a sibling checkout — override with `SHANIOS_TEST_OSI_HOST_DIR`), so
every one of these commands always runs your current working tree, never a
stale copy.

These run the real `install.sh`/`configure.sh` (from this repo) against
fresh loop-backed disks with a complete, realistic `OSI_*` environment. If
your change touches anything that handles a secret (LUKS passphrase, user
password, MOK enrollment password), run the `ps -eo pid,args` /
`/proc/*/cmdline` polling pattern from `shani-builder/AGENTS.md`
concurrently with the run and confirm the real secret value never
appears — this has been the exact class of bug found here before (a
secret leaking via `echo | cryptsetup`'s argv, and separately via a
`chroot ... bash -c '...' "$secret"` positional-argument pattern that
looked safe from shell-injection but wasn't safe from `ps aux`).

If your change touches string interpolation into `sed`/`awk` (usernames,
hostnames, any installer-supplied value), test with an adversarial value
containing the interpolation tool's own special characters (e.g. a
username containing `/` or `&` for `sed`) — the old code failing loudly
with a syntax error on that input is itself proof the interpolation was
unsafe; the fix should handle it silently and correctly instead.

## Audit-verified known issues (confirmed present)

- **MOK password random per-install (FIXED).** `scripts/configure.sh:939-1013` generates a random password via `openssl rand -base64 18 | tr -dc 'A-Za-z0-9'`, passes it as a positional argument to `mokutil`, and persists it to a root-only file via stdin tee.
- **`sign_efi_binary()` verified the live file only *after* replacing it —
  FIXED to verify before, matching the sibling implementation.** Found
  while comparing this function against `shani-deploy/scripts/
  gen-efi.sh`'s own `sign_efi_binary()` (both sign Secure Boot EFI
  binaries with `sbsign`, independently implemented). The original here
  signed to a temp file, `mv`'d it into the live position, *then* ran
  `sbverify` on the now-live file — restoring from backup if that failed.
  Functionally safe on the happy path, but it left a real, if narrow,
  window where the live binary could be observed already-replaced but not
  yet confirmed valid (e.g. a crash between the `mv` and that check).
  Moved the `sbverify` check to run on the *temp* file before the `mv`,
  matching `gen-efi.sh`'s exact ordering and its documented rationale
  ("the live file must never be observed in a signed-but-invalid state")
  — removed the now-redundant post-`mv` check rather than keep both
  (verifying twice was checking byte-identical content, and the old
  restore-from-backup path would have been broken anyway since the
  pre-`mv` fix path already deletes the backup once the pre-check
  passes). **Verified for real**: ran the actual real `install`+`configure`
  test-harness cycle (`shani-install-media`'s `test-env`, encrypted
  profile) end-to-end; the fixed function correctly signed-and-verified
  `grubx64.efi` and correctly hit the "already signed" fast path for the
  two pre-signed UKIs, exit 0 overall.
- **Config sections.** `config.yaml` has: `internet` (`connection_required`, `checker_url`), `welcome_page` (`logo`, `text`, `usage`), `disk.min_size` (28 GiB), `commands` (`browser`, `disks`, `reboot`, `wifi`).
- **yaml.SafeLoader.** `po/config_to_pot.py:92` uses `yaml.SafeLoader` — safe parsing.
- **CI status.** No CI workflows, has pre-commit hooks.
- **No unmount/luksClose cleanup on failure — FIXED.** Both scripts now
  push an undo command (`mount_tracked()`/`_push_cleanup`) onto a
  chronological stack immediately after every successful mount and LUKS
  open; `die()` and the ERR trap both unwind that stack in reverse (LIFO —
  children before parents, mapper closed only after whatever was mounted
  on top of it is gone) before exiting. A normal successful exit never
  triggers this — both scripts still intentionally leave the target
  mounted for the next stage. Also fixed a related, previously-undocumented
  problem this uncovered: almost every failure in these scripts is an
  explicit `|| { log_error ...; exit 1; }`/`|| die` pattern, and bash's
  `ERR` trap does **not** fire for a command whose failure is already
  handled by `||` — only for a genuinely unguarded failure under `set -e`.
  Verified with `bash -c 'trap "echo FIRED" ERR; false || { exit 1; }'`
  printing nothing. So the old shared trap was already dead code for
  nearly every real failure path in this repo, not just missing cleanup
  logic — `die()` (added to `install.sh`, already present but inert in
  `configure.sh`) is now the single choke point both the trap and every
  `||`-guarded failure funnel through. **Verified for real, not just by
  reading the diff**: ran the actual unmodified `install.sh`/`configure.sh`
  via `shani-install-media`'s real test harness
  (`./run_in_container.sh build.sh test install/configure -p gnome
  --encrypted`) end-to-end successfully (LUKS format/open, Btrfs
  subvolumes, real image extraction, MOK/Secure-Boot signing all
  completed) — confirming the cleanup additions don't interfere with the
  success path. Then temporarily injected a forced failure right after
  `mount_top_level` in a scratch copy of the flow, reran, and confirmed
  live: the LUKS mapper `shani_root` (checked via `ls /dev/mapper/` in a
  fresh privileged container sharing the host's real `/dev`) was open
  before the run and gone after the injected failure, with the cleanup
  log lines showing the exact unmount-then-close order described above.
- **`SWAPFILE_PATH` dead variable — FIXED.** `create_swapfile()` now
  reads `/mnt/${SWAPFILE_PATH}` instead of the hardcoded
  `/mnt/@swap/swapfile` it silently duplicated — verified by `bash -n` and
  by the real test-harness `install` run above (swapfile creation step
  reached the same code path; skipped only because the test disk didn't
  have enough free space, same as before this fix).

## Cross-repo impact — check before calling a fix complete

This repo's scripts are consumed and tested by `shani-install-media`
(`build.sh test install`/`configure`) and packaged by a PKGBUILD in
`shani-pkgbuilds` (`os-installer`/`os-installer-git`). A change to an
`OSI_*` variable's meaning, a new required variable, or a changed exit
code needs the test harness in `shani-install-media` updated to match, and
the packaging in `shani-pkgbuilds` checked for anything it assumes about
this repo's layout.

## Where things are documented

This repo's own script comments document each `OSI_*` variable's meaning
inline — read the full variable list at the top of `install.sh` and
`configure.sh` before assuming you know what a complete, valid environment
looks like; guessing at a subset has produced incomplete test runs before.
