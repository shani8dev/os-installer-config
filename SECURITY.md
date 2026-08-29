# Security Policy

## Trust Model

`os-installer-config` provides the `install.sh` and `configure.sh` scripts that
run once, as root, during a real Shanios OS install. The trust model is:

- **Secrets never exposed via argv/ps.** LUKS passphrase is written to a
  `mktemp`-created file (mode 600), passed via `--key-file=` to cryptsetup, then
  `shred -u`'d. MOK enrollment password is random per-install via
  `openssl rand -base64 18`, passed as a positional arg to `mokutil`, and
  persisted to a root-only file via stdin `tee`.
- **Parser safety.** YAML config is loaded with `yaml.SafeLoader` (not the
  unsafe `yaml.Loader`).

## Key Security Mechanisms

| Mechanism | Implementation |
|-----------|----------------|
| LUKS passphrase | mktemp key-file + `--key-file` + `shred -u` (`scripts/install.sh:302-337`) |
| MOK password | `openssl rand -base64 18` per-install; positional arg to `mokutil` (`scripts/configure.sh:939-1013`) |
| YAML parsing | `yaml.SafeLoader` (`po/config_to_pot.py`) |
| Secret stdin piping | `chpasswd` fed via stdin pipe, not argv (`scripts/configure.sh:538,599`) |

## Known Limitations

- **`bash -c` interpolation.** `scripts/configure.sh:786,887` interpolate
  installer-supplied values directly into `bash -c` strings instead of using
  positional args. A value containing a single quote can break the command or
  inject shell syntax.

## Reporting a Vulnerability

If you discover a security vulnerability in any Shanios project, please report it
responsibly by opening a private security advisory on GitHub.

Please include:
- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 72 hours and provide a detailed response
within 7 days. Thank you for helping keep Shanios secure.
