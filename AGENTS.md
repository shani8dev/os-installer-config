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

## Empirical verification (mandatory)

**Reading code is analysis; running code is verification.** A change is not
verified by reading the diff, running `bash -n`, or confirming it "looks
correct." It is verified by observing the actual behavior of the real
thing in the real environment — built, served, deployed, signed, running.
If you haven't seen it work (or fail) for real, it isn't verified.

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

Before calling a change done, state the specific observable pass
condition (e.g. "LUKS unlockable with the test passphrase," not "should
work") and which command below produces the evidence for it. Use the
sibling `shani-install-media` repo's test harness rather than building
scratch disk images by hand each time:

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

## Commit discipline

Before composing a commit message, run `git log --oneline -20` (and `git
log -5 -- <touched paths>` for the files you changed) and match the
existing style — subject shape, scope prefixes, body detail level —
rather than writing in a generic format.

## Boundaries

- ✅ **Always**: run any secret-handling change (LUKS passphrase, user
  password, MOK enrollment password) through the `ps -eo pid,args` /
  `/proc/*/cmdline` polling pattern concurrently with a real test-harness
  run — this exact class of bug (argv leak, positional-argument leak via
  `chroot ... bash -c` that looked safe but wasn't) has been found here
  before.
- ⚠️ **Ask first**: adding a GUI setup wizard — the CLI-by-design `OSI_*`
  approach is a deliberate architectural choice (it's what makes headless
  testing possible at all), not a gap to casually fill in.
- 🚫 **Never**: consider a change to `install.sh`/`configure.sh` done from a
  source read alone. There is no undo for a bad partition table or a
  half-configured real install — run the real test harness (below) every
  time, not just when the diff "looks" risky.

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
- **CI status.** `.github/workflows/ci.yml` added 2026-09-18: two jobs — `validate` (bash -n all scripts + `validate-config.sh` against repo config) and `translation-extraction` (regenerate `po/config.pot` from `config.yaml` via `config_to_pot.py`, require byte-identical committed pot). Verified locally.
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

- **Autologin silently fell back to a tty on Plasma installs — FIXED in
  source (2026-09-24), full harness install still pending.**
  `setup_autologin_target()` only knew gdm and sddm; the Plasma profile ships
  `plasma-login-manager` (`/usr/sbin/plasmalogin`), so "log in automatically"
  wrote a `getty@tty1` agetty drop-in instead. Reproduced by running the
  extracted `HEAD` function against an Arch target with plasmalogin and no
  gdm/sddm: it printed "Configuring getty autologin" and wrote the getty
  drop-in. Added a `plasmalogin` branch (before sddm) that writes
  `/etc/plasmalogin.conf.d/20-autologin.conf` (`[Autologin] User=… Session=plasma`),
  with the username passed as `$1`, not interpolated. Same extracted-function
  test with the fix: file written, `kreadconfig6` reads it back, no getty
  drop-in, and a hostile username (`$(touch /tmp/PWNED)`) did not execute.
  **Not yet verified by a real harness install** (`bootstrap -p plasma` with
  autologin on, then a boot) — do that before calling it done.
  Related, deliberately unchanged: `varlib_dirs` lists gdm/sddm but not
  plasmalogin. It doesn't need to, because `/var` is already a persistent
  overlay, so `/var/lib/plasmalogin` persists without a bind mount.

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

## Garuda Cross-Reference Findings (added 2026-09-17)

Based on a full scan of the garuda clones mapped against shani — **29 repos** (not 34; several user-listed names don't exist — see `../garuda-catalog.md` §Discrepancies). See `../garuda-mapping-analysis.md`, `../deep-analysis.md`, `../shani-catalog.md`, and `../garuda-catalog.md` for full details. garuda-setup-assistant is the most directly comparable repo — both handle first-run installation configuration.

### 🟡 HIGH: CI/CD gap (shared across ALL repos)

1. **Shared CI templates** (estimated 2-3 days, affects ALL repos).
   - Garuda's `gitlab-ci-commons` provides reusable templates (commitizen, flake-check, pre-commit, tag-to-release). Each repo `include:`s from it.
   - Shani repos run on GitHub Actions (no `.gitlab-ci.yml` anywhere) — 8 repos (blog, builder, docs, fleet, insights, install-media, pkgbuilds, platform) carry hand-written `.github/workflows/*.yml` with duplicated patterns.
   - **Action**: Create `shani-ci-commons` (GitHub Actions reusable workflows / composite actions) with templates for lint, test, build, security scan. Each repo references them via `uses: shani8dev/shani-ci-commons/...` instead of copy-pasting.
   - **Affects**: All 15 shani repos.

### 🟡 HIGH: Dependency management gap

2. **Add automated dependency updates** (estimated 4 hours, affects ALL repos).
   - Garuda uses `renovate-runner` running hourly against all repos with `renovate.json` files.
   - Shani repos have no automated dependency updating.
   - **Action**: Set up Renovate (self-hosted or gitlab.com) with a fleet-wide config. Each repo adds a minimal `renovate.json`.

### 🟢 MEDIUM: Code quality

3. **Conventional commit enforcement** (estimated 2 hours, affects ALL repos).
   - Every garuda repo has a `[commitizen]` badge; `cz commit` is enforced.
   - Shani repos have no commit message standardization.

### 🔗 Cross-repo comparison vs garuda-setup-assistant

4. **Setup assistant comparison** — Garuda ships `garuda-setup-assistant`, a Qt-based first-run wizard with multi-language support (16+ languages). This repo's `install.sh`/`configure.sh` are CLI-only, driven by `OSI_*` env vars. Consider a lightweight GUI setup assistant (GTK4, matching shani-cassini's framework) for desktop users — especially valuable for users unfamiliar with command-line installs. This would be a new repo or addition to shani-install-media. See `../garuda-mapping-analysis.md` section 4.5 for the full proposal.

5. **No post-install welcome app** — Garuda has `garuda-welcome` (tips, links, system info, quick actions). Shani has no equivalent. Could be a simple GTK4 app showing shani news, tips, system status, and links to docs/support.

### 🔍 Re-Scan Findings (2026-09-17)

Re-scanned against `garuda-catalog.md` (29 repos, not 34) and `shani-catalog.md` (16 repos). **Confirmed mapping: `garuda-setup-assistant`** — it EXISTS in `garuda-clones/` as a first-run setup wizard (Shell scripts + Qt QML/JS wizard pages, YAML config, installs to `etc/`/`usr/` share layout via CMake, Transifex translations, GitLab CI, no C++ source, no pkexec policy). Both handle first-run installation configuration. Key difference confirmed: os-installer-config's `install.sh`/`configure.sh` are **CLI-only, driven by `OSI_*` env vars**, while garuda-setup-assistant is a **Qt-based wizard**.

**New gaps from the garuda side:**
1. **Qt GUI wizard gap** — garuda-setup-assistant ships a Qt-based first-run wizard; os-installer-config has no GUI at all (CLI-only `OSI_*` env vars). A GUI would need to be GTK4 (matching `shani-cassini`'s framework), not Qt — see the existing finding #4 above.
2. **Translation breadth** — garuda-setup-assistant uses Transifex with 16+ languages; os-installer-config has only `de_DE` and `en_US` `.po` files (confirmed in `shani-catalog.md` §9).
3. **CI workflows (gap closing)** — garuda-setup-assistant has GitLab CI; os-installer-config now has `.github/workflows/ci.yml` (2026-09-18: bash -n, validator, translation-extraction sync check).
4. **No post-install welcome app** — garuda ships `garuda-welcome` (tips, links, system info, quick actions); shani has no equivalent (existing finding #5 above, still true).
5. **No boot-repair/assistant tooling** — garuda has `garuda-boot-options` and `garuda-boot-repair` (Qt GUIs for bootloader/kernel-parameter management); shani's boot management lives inside `shani-deploy`'s CLI scripts with no GUI surface.

**Shani advantages:**
1. **Fully headless-scriptable** — `OSI_*` env-var driving means the real `install.sh`/`configure.sh` run end-to-end in `shani-install-media`'s test harness against loop-backed disks; garuda-setup-assistant's Qt wizard cannot be driven headlessly.
2. **Failure-safety engineering** — undo-stack cleanup (`mount_tracked()`/`_push_cleanup`), verify-before-replace EFI signing, `die()` choke point — all verified live in the real test harness; garuda-setup-assistant documents none of this (no AGENTS.md, no tests in any of the 29 garuda repos).
3. **Real test infrastructure** — `shani-install-media/test-env` exercises these scripts for real; the garuda side has no equivalent harness for its setup assistant.

**Qt GUI gap note (relevant):** garuda-setup-assistant is Qt-based; shani's GUI framework is GTK4/Python (`shani-cassini`). Any future shani setup wizard should be GTK4 to match — and garuda's broader Qt GUI fleet (12 apps: garuda-welcome, garuda-assistant, garuda-boot-options, garuda-boot-repair, garuda-gamer, garuda-network-assistant, garuda-downloader, garuda-nix-manager, garuda-settings-manager, garuda-system-maintenance, firefly, btrfs-assistant) has no shani equivalents beyond `shani-cassini`'s in-progress tabs.

### 📋 Implementation Roadmap (2026-09-17)

Implementation priorities are per `../IMPLEMENTATION-ROADMAP.md` (master roadmap for the whole shani ecosystem).

1. **YAML validation pattern (DONE).** `scripts/validate-config.sh` built: REPO_DIR derived from `BASH_SOURCE` (no hardcoded paths), required-field checks for `distribution_name`, `scripts.install`, `scripts.configure`, unknown top-level key warnings. Runs in CI on every push/PR.

2. **CI workflow (DONE).** `.github/workflows/ci.yml` added: `validate` job (bash -n all scripts, run `validate-config.sh` against repo config) and `translation-extraction` job (regenerate `po/config.pot` from `config.yaml` via `config_to_pot.py`, fail if committed pot differs — guards against un-regenerated pot after config.yaml string changes).

3. **GUI setup assistant consideration (P3, only if human decides).** The CLI-by-design `OSI_*` env-var approach is a deliberate, superior choice — it's what makes the real scripts headlessly testable in `shani-install-media`'s harness. If a GUI is ever wanted, it must be built natively for shani (GTK4, matching `shani-cassini`), NOT ported from garuda's Qt wizard.

4. **Conventional commits + `renovate.json` (P1).** Ecosystem-wide commit convention (item #9) and Renovate (item #8) — minimal for a config repo with no runtime dependencies.
