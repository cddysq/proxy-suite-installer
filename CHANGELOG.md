# Changelog

## [0.1.0] - 2026-04-08

### Added
- One-shot installer for Clash Verge Rev on WSL/Linux and macOS.
- `proxy on|off|status|test|update|uninstall` command suite.
- Idempotent reinstall with managed shell blocks (no duplicates).
- SHA256 digest verification for downloaded release assets.
- Automatic shell integration for bash and zsh.
- Tool proxy configuration: git, npm, pnpm, yarn, pip.
- APT proxy file management (Linux only).
- macOS DMG mount/unmount install with Gatekeeper-aware app placement.
- `--skip-clash-install`, `--skip-font-install`, `--force`, `--latest`, `--version`, `--no-modify-shell`, `--yes` flags.
- `--shell-file <path>` flag for custom shell rc file targeting.
- Colored terminal output with `NO_COLOR` / `CI` convention support.
- `proxy update` subcommand for refreshing the command suite in-place.
- `proxy uninstall` with interactive prompts, `--purge-config`, and `--remove-app` flags.
- `proxy status -v` verbose diagnostic output.
- Pipe mode support: `curl -fsSL ... | bash`.
- Landing page with i18n (Chinese/English), terminal-style install box.
