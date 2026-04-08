[English](./README.md) | [中文](./README.zh-CN.md)

# Proxy Suite Installer

One-command setup for [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) plus a shell command suite that manages proxy state across your terminal tools.

## Quick Start

**Online install** (recommended):

```bash
curl -fsSL https://proxy.wusaqi.me/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/cddysq/proxy-suite-installer.git
bash proxy-suite-installer/install.sh
```

After install, open a new shell and run:

```bash
proxy on          # start Clash Verge + enable proxy
proxy test        # verify ports + outbound connectivity
proxy status      # show compact state overview
proxy off         # stop everything and clean env
```

## Requirements

| Platform | Prerequisites |
|----------|--------------|
| **WSL / Linux** | `bash`, `curl`, `awk`, `sed`, `grep`, `cut` — all pre-installed on Ubuntu/Debian/Fedora |
| **macOS** | `bash`, `curl`, `hdiutil` — ships with macOS; tested on Intel and Apple Silicon |

## Installer Flags

| Flag | Description |
|------|-------------|
| `--latest` | Resolve the latest Clash Verge release tag at install time |
| `--version <tag>` | Pin an explicit release tag (e.g. `v2.4.7`) |
| `--skip-clash-install` | Refresh only the proxy command suite, skip Clash download |
| `--no-modify-shell` | Do not patch `.bashrc` / `.zshrc` |
| `--skip-font-install` | Skip Linux CJK font packages |
| `--shell-file <path>` | Patch only one specific shell rc file |
| `--force` | Reinstall even if the target version matches |
| `--yes` | Auto-confirm prompts |
| `-h`, `--help` | Show help message |

## Commands

| Command | Description |
|---------|-------------|
| `proxy on` | Start Clash Verge, write env file, configure git/npm/pnpm/yarn/pip proxy and APT proxy (Linux) |
| `proxy off` | Stop Clash Verge, remove env file, clear tool proxy |
| `proxy status` | Show compact daily status |
| `proxy status -v` | Show verbose diagnostic (ports, config, env, tool proxy) |
| `proxy test [URL]` | Validate local ports and outbound HTTP/SOCKS5 egress (defaults to `https://api.github.com/meta`) |
| `proxy update` | Re-run installer to refresh the command suite in-place |
| `proxy uninstall` | Remove the local command suite, shell integration, and runtime files |

## How It Works

```
install.sh
 ├── Download & verify Clash Verge Rev (.deb/.rpm/.dmg)
 ├── Install package via apt/dnf/rpm or copy .app to /Applications
 ├── Write 7 scripts to ~/bin/
 │    ├── clash-proxy-lib.sh      (shared functions)
 │    ├── clash-proxy-on.sh       (enable flow)
 │    ├── clash-proxy-off.sh      (disable flow)
 │    ├── clash-proxy-status.sh   (status display)
 │    ├── clash-proxy-test.sh     (connectivity check)
 │    ├── proxy                   (unified CLI entrypoint)
 │    └── proxy-uninstall         (cleanup tool)
 ├── Patch .bashrc / .zshrc with managed blocks
 └── Write install metadata to ~/.local/share/proxy-suite-installer/
```

**Managed blocks** use `# >>> marker >>>` / `# <<< marker <<<` delimiters. Reinstalling replaces blocks in-place — no duplication, no manual cleanup.

**SHA256 verification** checks downloaded assets against the `digest` field in GitHub Release API responses.

## Updating

```bash
proxy update             # refreshes command suite from the original install.sh
# or
bash install.sh --force  # full reinstall including Clash Verge binary
```

## Uninstalling

```bash
proxy uninstall
# or
bash uninstall.sh
```

Interactive prompts let you choose whether to also remove Clash Verge app/config data.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `proxy: command not found` | Open a new shell or run `source ~/.bashrc` |
| `proxy on` says "failed to launch" | Check if WSLg is available: `echo $DISPLAY` |
| `proxy test` shows port not listening | Start Clash Verge GUI first, or check `proxy status -v` |
| Env not loaded in current shell | Use the shell function (`proxy on`), not `proxy on` in a subshell |

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-shot installer entrypoint |
| `uninstall.sh` | Convenience launcher for the installed `proxy-uninstall` |
| `versions.env` | Maintainer-facing pinned versions |
| `.gitattributes` | Force LF line endings for WSL/macOS compatibility |
| `.editorconfig` | Editor formatting rules |
| `.shellcheckrc` | ShellCheck lint configuration |

## License

[MIT](./LICENSE)
