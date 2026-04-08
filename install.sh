#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$SCRIPT_PATH" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
else
  # pipe mode: curl ... | bash
  SCRIPT_DIR=""
fi

PROXY_SUITE_VERSION="0.1.0"
CLASH_VERGE_VERSION="v2.4.7"
INSTALL_CHANNEL="pinned"
INSTALL_REMOTE_URL="https://raw.githubusercontent.com/cddysq/proxy-suite-installer/main/install.sh"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/versions.env" ]; then
  # Validate versions.env contains only safe variable assignments
  if grep -qvE '^\s*(#|$|[A-Z_]+="[^"]*"\s*$)' "$SCRIPT_DIR/versions.env" 2>/dev/null; then
    printf '[proxy-installer] WARN: versions.env contains unexpected content; skipping\n' >&2
  else
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/versions.env"
  fi
fi

SKIP_CLASH_INSTALL=0
USE_LATEST=0
REQUESTED_VERSION=""
YES_TO_ALL=0
SKIP_FONT_INSTALL=0
TARGET_SHELL_FILE=""
NO_MODIFY_SHELL=0
FORCE_REINSTALL=0
CLASH_INSTALL_ACTION=""

[ -n "${HOME:-}" ] || { printf '[proxy-installer] ERROR: $HOME is not set\n' >&2; exit 1; }

BIN_DIR="${BIN_DIR:-$HOME/bin}"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/proxy-suite-installer}"
LOG_DIR="${LOG_DIR:-$HOME/.local/var/log}"
TMP_DIR=""

# Color output (auto-detect; honors CI and NO_COLOR conventions)
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ -z "${CI:-}" ]; then
  _C_RESET='\033[0m'; _C_BOLD='\033[1m'
  _C_GREEN='\033[32m'; _C_YELLOW='\033[33m'; _C_RED='\033[31m'; _C_CYAN='\033[36m'
else
  _C_RESET=''; _C_BOLD=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_CYAN=''
fi

log()  { printf '%b[proxy-installer]%b %s\n' "$_C_CYAN" "$_C_RESET" "$*" >&2; }
warn() { printf '%b[proxy-installer] WARN:%b %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()  { printf '%b[proxy-installer] ERROR:%b %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Options:
  --latest               install latest Clash Verge release via GitHub API
  --version <tag>        install a specific Clash Verge tag, e.g. v2.4.7
  --skip-clash-install   do not install/update Clash Verge; install command suite only
  --skip-font-install    skip Linux CJK font packages
  --shell-file <path>    patch only one explicit shell rc file
  --no-modify-shell      do not touch .bashrc/.zshrc; install commands only
  --force                reinstall even if the target version is already installed
  --yes                  auto-confirm prompts where possible
  -h, --help             show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --latest)
      USE_LATEST=1
      shift
      ;;
    --version)
      [ $# -ge 2 ] || die "--version requires a value"
      case "$2" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) die "--version value must be semver format (e.g. v2.4.7)" ;;
      esac
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    --skip-clash-install)
      SKIP_CLASH_INSTALL=1
      shift
      ;;
    --skip-font-install)
      SKIP_FONT_INSTALL=1
      shift
      ;;
    --shell-file)
      [ $# -ge 2 ] || die "--shell-file requires a value"
      case "$2" in
        /*|~/*|./*) ;;
        *) die "--shell-file must be an absolute or relative path (e.g. ~/.bashrc)" ;;
      esac
      [ -f "$2" ] || die "--shell-file target does not exist: $2"
      TARGET_SHELL_FILE="$2"
      shift 2
      ;;
    --no-modify-shell)
      NO_MODIFY_SHELL=1
      shift
      ;;
    --force)
      FORCE_REINSTALL=1
      shift
      ;;
    --yes)
      YES_TO_ALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 — please install it and re-run"
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s' 'amd64' ;;
    aarch64|arm64) printf '%s' 'arm64' ;;
    armv7l|armv7|armhf) printf '%s' 'armhf' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

detect_os() {
  case "$(uname -s)" in
    Linux) printf '%s' 'linux' ;;
    Darwin) printf '%s' 'darwin' ;;
    *) die "unsupported operating system: $(uname -s)" ;;
  esac
}

detect_pkg_family() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s' 'deb'
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s' 'rpm'
  elif command -v rpm >/dev/null 2>&1; then
    printf '%s' 'rpm'
  else
    die "unsupported Linux package manager; expected apt-get, dnf, or rpm"
  fi
}

prime_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    return 0
  fi

  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi

  if [ "$YES_TO_ALL" -eq 1 ] && ! [ -t 0 ]; then
    die "sudo password is required, but no interactive TTY is available"
  fi

  log "Requesting sudo once for package install / removal steps"
  sudo -v
}

mktemp_dir() {
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP PIPE
}

fetch_release_json_for_version() {
  local version="$1"
  local cache_file="$TMP_DIR/release-${version#v}.json"
  if [ ! -f "$cache_file" ]; then
    need_cmd curl
    curl --proto '=https' -fsSL "https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/tags/${version}" -o "$cache_file"
  fi
  printf '%s' "$cache_file"
}

asset_digest_from_release_json() {
  local json_file="$1"
  local asset_name="$2"
  awk -F'"' -v asset="$asset_name" '
    $2 == "name" { current = $4 }
    $2 == "digest" && current == asset {
      split($4, parts, ":")
      print parts[2]
      exit
    }
  ' "$json_file"
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return 0
  fi
  return 1
}

verify_release_asset_digest() {
  local version="$1"
  local asset_name="$2"
  local file="$3"
  local json_file expected actual

  json_file="$(fetch_release_json_for_version "$version")"
  expected="$(asset_digest_from_release_json "$json_file" "$asset_name")"
  if [ -z "$expected" ]; then
    warn "no official digest found for $asset_name; skipping checksum verification"
    return 0
  fi

  actual="$(file_sha256 "$file")" || die "unable to compute sha256 for $file"
  if [ "$actual" != "$expected" ]; then
    die "sha256 mismatch for $asset_name (expected $expected, got $actual)"
  fi
  log "Verified sha256 for $asset_name"
}

installed_clash_version_linux() {
  local status_line status version
  if command -v dpkg-query >/dev/null 2>&1; then
    status_line="$(dpkg-query -W -f='${db:Status-Status} ${Version}\n' clash-verge 2>/dev/null || true)"
    status="${status_line%% *}"
    version="${status_line#* }"
    if [ "$status" = 'installed' ] && [ -n "$version" ] && [ "$version" != "$status_line" ]; then
      printf '%s' "$version"
    fi
    return 0
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}\n' clash-verge 2>/dev/null || true
  fi
}

installed_clash_version_macos() {
  local app_path="$1"
  [ -n "$app_path" ] && [ -d "$app_path" ] || return 0
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true
    return 0
  fi
  defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
}

fetch_latest_tag() {
  need_cmd curl
  curl --proto '=https' -fsSL "https://api.github.com/repos/clash-verge-rev/clash-verge-rev/releases/latest" |
    sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

resolve_clash_version() {
  if [ -n "$REQUESTED_VERSION" ]; then
    printf '%s' "$REQUESTED_VERSION"
    return 0
  fi

  if [ "$USE_LATEST" -eq 1 ] || [ "${INSTALL_CHANNEL:-}" = "latest" ]; then
    local latest
    latest="$(fetch_latest_tag)"
    [ -n "$latest" ] || die "failed to resolve latest Clash Verge release"
    printf '%s' "$latest"
    return 0
  fi

  printf '%s' "$CLASH_VERGE_VERSION"
}

version_without_v() {
  printf '%s' "${1#v}"
}

asset_name_for_platform() {
  local os="$1"
  local arch="$2"
  local version="$3"
  local version_no_v
  version_no_v="$(version_without_v "$version")"

  if [ "$os" = 'linux' ]; then
    local family
    family="$(detect_pkg_family)"
    case "$family:$arch" in
      deb:amd64) printf '%s' "Clash.Verge_${version_no_v}_amd64.deb" ;;
      deb:arm64) printf '%s' "Clash.Verge_${version_no_v}_arm64.deb" ;;
      deb:armhf) printf '%s' "Clash.Verge_${version_no_v}_armhf.deb" ;;
      rpm:amd64) printf '%s' "Clash.Verge-${version_no_v}-1.x86_64.rpm" ;;
      rpm:arm64) printf '%s' "Clash.Verge-${version_no_v}-1.aarch64.rpm" ;;
      rpm:armhf) printf '%s' "Clash.Verge-${version_no_v}-1.armhfp.rpm" ;;
      *) die "unsupported Linux asset combination: $family / $arch" ;;
    esac
    return 0
  fi

  case "$arch" in
    amd64) printf '%s' "Clash.Verge_${version_no_v}_x64.dmg" ;;
    arm64) printf '%s' "Clash.Verge_${version_no_v}_aarch64.dmg" ;;
    *) die "unsupported macOS asset architecture: $arch" ;;
  esac
}

download_release_asset() {
  local version="$1"
  local asset_name="$2"
  local dest="$3"

  need_cmd curl
  local url
  url="https://github.com/clash-verge-rev/clash-verge-rev/releases/download/${version}/${asset_name}"
  log "Downloading $asset_name"
  curl --proto '=https' -fSL --progress-bar --retry 3 --retry-delay 2 -o "$dest" "$url"
  verify_release_asset_digest "$version" "$asset_name" "$dest"
}

install_linux_fonts() {
  local package
  if [ "$SKIP_FONT_INSTALL" -eq 1 ]; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    return 0
  fi

  for package in fonts-noto-cjk fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-color-emoji; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      prime_sudo
      log "Installing Linux CJK fonts for GUI text rendering"
      sudo apt-get update -qq >/dev/null
      sudo apt-get install -y -qq fonts-noto-cjk fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-color-emoji >/dev/null
      return 0
    fi
  done

  log "Linux CJK fonts already installed; skipping"
}

install_clash_linux() {
  local version="$1"
  local arch="$2"
  local current_version
  local target_version
  target_version="$(version_without_v "$version")"
  current_version="$(installed_clash_version_linux)"
  if [ "$current_version" = "$target_version" ] && [ "$FORCE_REINSTALL" -eq 0 ]; then
    log "Clash Verge Rev $target_version already installed; skipping package download"
    CLASH_INSTALL_ACTION='skipped-already-current'
    return 0
  fi
  if [ "$current_version" = "$target_version" ] && [ "$FORCE_REINSTALL" -eq 1 ]; then
    log "Clash Verge Rev $target_version already installed; forcing reinstall"
  fi
  local asset
  asset="$(asset_name_for_platform linux "$arch" "$version")"
  local pkg_file="$TMP_DIR/$asset"
  download_release_asset "$version" "$asset" "$pkg_file"

  prime_sudo
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing Clash Verge Rev via apt"
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y -qq "$pkg_file" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing Clash Verge Rev via dnf"
    sudo dnf install -y -q "$pkg_file" >/dev/null
  else
    log "Installing Clash Verge Rev via rpm"
    sudo rpm -Uvh --replacepkgs "$pkg_file" >/dev/null
  fi
  CLASH_INSTALL_ACTION='installed-or-updated'
}

install_clash_macos() {
  local version="$1"
  local arch="$2"
  local existing_app=''
  local current_version=''
  local target_version
  target_version="$(version_without_v "$version")"
  if [ -d "/Applications/Clash Verge.app" ]; then
    existing_app="/Applications/Clash Verge.app"
  elif [ -d "$HOME/Applications/Clash Verge.app" ]; then
    existing_app="$HOME/Applications/Clash Verge.app"
  fi
  current_version="$(installed_clash_version_macos "$existing_app")"
  if [ "$current_version" = "$target_version" ] && [ "$FORCE_REINSTALL" -eq 0 ]; then
    printf '%s' "$existing_app" > "$TMP_DIR/macos_app_path"
    log "Clash Verge Rev $target_version already installed; skipping dmg download"
    CLASH_INSTALL_ACTION='skipped-already-current'
    return 0
  fi
  if [ "$current_version" = "$target_version" ] && [ "$FORCE_REINSTALL" -eq 1 ]; then
    log "Clash Verge Rev $target_version already installed; forcing reinstall"
  fi
  local asset
  asset="$(asset_name_for_platform darwin "$arch" "$version")"
  local dmg_file="$TMP_DIR/$asset"
  local mount_dir="$TMP_DIR/mnt"
  local app_dest app_source

  need_cmd hdiutil
  need_cmd open
  download_release_asset "$version" "$asset" "$dmg_file"

  mkdir -p "$mount_dir"
  hdiutil attach "$dmg_file" -mountpoint "$mount_dir" -nobrowse >/dev/null
  trap 'hdiutil detach "$mount_dir" >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT INT TERM HUP PIPE
  app_source="$(find "$mount_dir" -maxdepth 1 -type d -name '*.app' | head -n 1)"
  [ -n "$app_source" ] || die "failed to locate Clash Verge.app inside mounted dmg"

  if [ -w /Applications ] || sudo -n true >/dev/null 2>&1 || [ "$YES_TO_ALL" -eq 1 ] || [ -t 0 ]; then
    if ! [ -w /Applications ]; then
      prime_sudo
      sudo rm -rf "/Applications/$(basename "$app_source")"
      sudo cp -R "$app_source" /Applications/
    else
      rm -rf "/Applications/$(basename "$app_source")"
      cp -R "$app_source" /Applications/
    fi
    app_dest="/Applications/$(basename "$app_source")"
  else
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$(basename "$app_source")"
    cp -R "$app_source" "$HOME/Applications/"
    app_dest="$HOME/Applications/$(basename "$app_source")"
  fi

  hdiutil detach "$mount_dir" >/dev/null
  trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP PIPE
  printf '%s' "$app_dest" > "$TMP_DIR/macos_app_path"
  CLASH_INSTALL_ACTION='installed-or-updated'
}

determine_shell_files() {
  local primary secondary
  if [ -n "$TARGET_SHELL_FILE" ]; then
    printf '%s\n' "$TARGET_SHELL_FILE"
    return 0
  fi

  if [ -n "${SHELL:-}" ] && printf '%s' "$SHELL" | grep -q 'zsh$'; then
    primary="$HOME/.zshrc"
    secondary="$HOME/.bashrc"
  else
    primary="$HOME/.bashrc"
    secondary="$HOME/.zshrc"
  fi

  # Output primary if it exists, otherwise fall back to secondary or create primary
  if [ -f "$primary" ]; then
    printf '%s\n' "$primary"
  elif [ ! -f "$secondary" ]; then
    printf '%s\n' "$primary"
  fi

  # Output secondary if it exists (avoids duplicate when only secondary exists)
  if [ -f "$secondary" ]; then
    printf '%s\n' "$secondary"
  fi
}

replace_managed_block() {
  local file="$1"
  local marker="$2"
  local content="$3"
  local start end tmp

  touch "$file"
  start="# >>> ${marker} >>>"
  end="# <<< ${marker} <<<"
  tmp="$(mktemp)"

  # Remove existing managed block and strip trailing blank lines
  awk -v start="$start" -v end="$end" '
    BEGIN { skip = 0 }
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] == "") last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' > "$tmp"

  {
    if [ -s "$tmp" ]; then
      cat "$tmp"
      printf '\n'
    fi
    printf '%s\n' "$start"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } > "$file"

  rm -f "$tmp"
}

write_proxy_files() {
  mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR"

  cat > "$BIN_DIR/clash-proxy-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
BIN_DIR="${BIN_DIR:-$HOME/bin}"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/proxy-suite-installer}"
META_FILE="$STATE_DIR/install-meta.env"
ENV_FILE="${ENV_FILE:-$HOME/.config/clash-proxy.env}"
LOG_FILE="${LOG_FILE:-$HOME/.local/var/log/clash-verge.log}"
APT_FILE="/etc/apt/apt.conf.d/95clash-proxy"
NO_PROXY_VALUE="localhost,127.0.0.1,::1,.local,.localdomain"

DEFAULT_APP_DIR_LINUX="$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev"
DEFAULT_APP_DIR_MACOS="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
DEFAULT_HOST="127.0.0.1"
DEFAULT_MIXED_PORT="7897"
DEFAULT_SOCKS_PORT="7898"
DEFAULT_HTTP_PORT="7899"
DEFAULT_CTRL_ADDR="127.0.0.1:9097"

if [ -f "$META_FILE" ]; then
  # shellcheck disable=SC1090
  . "$META_FILE"
fi

APP_DIR="${CLASH_PROXY_APP_DIR:-}"
if [ -z "$APP_DIR" ]; then
  case "$OS_NAME" in
    linux) APP_DIR="$DEFAULT_APP_DIR_LINUX" ;;
    darwin) APP_DIR="$DEFAULT_APP_DIR_MACOS" ;;
    *) APP_DIR="$DEFAULT_APP_DIR_LINUX" ;;
  esac
fi

CORE_CFG="$APP_DIR/config.yaml"
VERGE_CFG="$APP_DIR/verge.yaml"

normalize_value() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  case "$value" in
    ''|null|NULL|undefined|Undefined|None|none) printf '%s' '<unset>' ;;
    *) printf '%s' "$value" ;;
  esac
}

is_true() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true|1|yes|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

require_file() {
  local path="$1"
  [ -f "$path" ] || { echo "missing file: $path" >&2; return 1; }
}

get_yaml_scalar() {
  local key="$1"
  local file="$2"
  local value
  [ -f "$file" ] || return 0
  value="$(grep -E "^${key}:" "$file" | head -n 1 | cut -d: -f2- | sed 's/^ *//')"
  printf '%s' "$value"
}

load_config() {
  CONFIG_READY=0

  HOST="$DEFAULT_HOST"
  DECLARED_MIXED_PORT="$DEFAULT_MIXED_PORT"
  DECLARED_SOCKS_PORT="$DEFAULT_SOCKS_PORT"
  DECLARED_HTTP_PORT="$DEFAULT_HTTP_PORT"
  CTRL_ADDR="$DEFAULT_CTRL_ADDR"
  VERGE_SOCKS_ENABLED_RAW='false'
  VERGE_HTTP_ENABLED_RAW='false'
  ENABLE_EXTERNAL_CONTROLLER_RAW='false'

  if [ -f "$CORE_CFG" ]; then
    HOST="$(normalize_value "$(get_yaml_scalar proxy_host "$VERGE_CFG")")"
    DECLARED_MIXED_PORT="$(normalize_value "$(get_yaml_scalar mixed-port "$CORE_CFG")")"
    DECLARED_SOCKS_PORT="$(normalize_value "$(get_yaml_scalar socks-port "$CORE_CFG")")"
    DECLARED_HTTP_PORT="$(normalize_value "$(get_yaml_scalar port "$CORE_CFG")")"
    CTRL_ADDR="$(normalize_value "$(get_yaml_scalar external-controller "$CORE_CFG")")"
  fi

  if [ -f "$VERGE_CFG" ]; then
    VERGE_SOCKS_ENABLED_RAW="$(normalize_value "$(get_yaml_scalar verge_socks_enabled "$VERGE_CFG")")"
    VERGE_HTTP_ENABLED_RAW="$(normalize_value "$(get_yaml_scalar verge_http_enabled "$VERGE_CFG")")"
    ENABLE_EXTERNAL_CONTROLLER_RAW="$(normalize_value "$(get_yaml_scalar enable_external_controller "$VERGE_CFG")")"
  fi

  [ -f "$CORE_CFG" ] && [ -f "$VERGE_CFG" ] && CONFIG_READY=1

  [ "$HOST" = '<unset>' ] && HOST="$DEFAULT_HOST"
  [ "$DECLARED_MIXED_PORT" = '<unset>' ] && DECLARED_MIXED_PORT="$DEFAULT_MIXED_PORT"
  [ "$DECLARED_SOCKS_PORT" = '<unset>' ] && DECLARED_SOCKS_PORT="$DEFAULT_SOCKS_PORT"
  [ "$DECLARED_HTTP_PORT" = '<unset>' ] && DECLARED_HTTP_PORT="$DEFAULT_HTTP_PORT"
  [ "$CTRL_ADDR" = '<unset>' ] && CTRL_ADDR="$DEFAULT_CTRL_ADDR"

  EFFECTIVE_HTTP_PORT="$DECLARED_MIXED_PORT"
  EFFECTIVE_SOCKS_PORT="$DECLARED_MIXED_PORT"
  HTTP_URL="http://${HOST}:${EFFECTIVE_HTTP_PORT}"
  SOCKS_URL="socks5://${HOST}:${EFFECTIVE_SOCKS_PORT}"
  CTRL_PORT="${CTRL_ADDR##*:}"
}

is_clash_running() {
  if pgrep -x clash-verge >/dev/null 2>&1 || pgrep -x verge-mihomo >/dev/null 2>&1; then
    return 0
  fi
  if [ "$OS_NAME" = 'darwin' ] && pgrep -f 'Clash Verge' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

clash_processes() {
  if [ "$OS_NAME" = 'darwin' ]; then
    pgrep -fl clash-verge || true
    pgrep -fl verge-mihomo || true
    pgrep -fl 'Clash Verge' || true
  else
    pgrep -ax clash-verge || true
    pgrep -ax verge-mihomo || true
  fi
}

listen_output() {
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || true
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null || true
    return 0
  fi
}

active_ports_output() {
  listen_output | grep -E '127\.0\.0\.1:(7895|7896|7897|7898|7899|9097)|localhost:(7895|7896|7897|7898|7899|9097)|\*\.?(7895|7896|7897|7898|7899|9097)' || true
}

port_listening() {
  local port="$1"
  listen_output | grep -Eq "[:.]${port}([^0-9]|$)"
}

mixed_port_listening() {
  load_config
  port_listening "$DECLARED_MIXED_PORT"
}

controller_listening() {
  load_config
  port_listening "$CTRL_PORT"
}

env_file_exists() {
  [ -f "$ENV_FILE" ]
}

current_shell_proxy_loaded() {
  [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${all_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ] || [ -n "${ALL_PROXY:-}" ]
}

source_env_file_if_present() {
  if env_file_exists; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi
}

clear_current_shell_env() {
  unset CLASH_PROXY_HOST CLASH_PROXY_PORT CLASH_HTTP_PROXY_URL CLASH_SOCKS_PROXY_URL CLASH_CONTROLLER_ADDR
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
}

write_env_file() {
  load_config
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<ENVEOF
export CLASH_PROXY_HOST="$HOST"
export CLASH_PROXY_PORT="$DECLARED_MIXED_PORT"
export CLASH_HTTP_PROXY_URL="$HTTP_URL"
export CLASH_SOCKS_PROXY_URL="$SOCKS_URL"
export CLASH_CONTROLLER_ADDR="$CTRL_ADDR"
export http_proxy="$HTTP_URL"
export https_proxy="$HTTP_URL"
export all_proxy="$SOCKS_URL"
export HTTP_PROXY="$HTTP_URL"
export HTTPS_PROXY="$HTTP_URL"
export ALL_PROXY="$SOCKS_URL"
export no_proxy="$NO_PROXY_VALUE"
export NO_PROXY="$NO_PROXY_VALUE"
ENVEOF
}

apply_tool_proxy() {
  local http_url="$1"
  if command -v git >/dev/null 2>&1; then
    git config --global http.proxy "$http_url"
    git config --global https.proxy "$http_url"
  fi
  if command -v npm >/dev/null 2>&1; then
    npm config set proxy "$http_url" >/dev/null
    npm config set https-proxy "$http_url" >/dev/null
  fi
  if command -v pnpm >/dev/null 2>&1; then
    pnpm config set proxy "$http_url" >/dev/null 2>&1 || true
    pnpm config set https-proxy "$http_url" >/dev/null 2>&1 || true
  fi
  if command -v yarn >/dev/null 2>&1; then
    yarn config set proxy "$http_url" >/dev/null 2>&1 || true
    yarn config set https-proxy "$http_url" >/dev/null 2>&1 || true
  fi
  if command -v pip3 >/dev/null 2>&1; then
    pip3 config set global.proxy "$http_url" >/dev/null 2>&1 || true
  elif command -v pip >/dev/null 2>&1; then
    pip config set global.proxy "$http_url" >/dev/null 2>&1 || true
  fi
}

clear_tool_proxy() {
  if command -v git >/dev/null 2>&1; then
    git config --global --unset-all http.proxy >/dev/null 2>&1 || true
    git config --global --unset-all https.proxy >/dev/null 2>&1 || true
  fi
  if command -v npm >/dev/null 2>&1; then
    npm config delete proxy >/dev/null 2>&1 || true
    npm config delete https-proxy >/dev/null 2>&1 || true
  fi
  if command -v pnpm >/dev/null 2>&1; then
    pnpm config delete proxy >/dev/null 2>&1 || true
    pnpm config delete https-proxy >/dev/null 2>&1 || true
  fi
  if command -v yarn >/dev/null 2>&1; then
    yarn config delete proxy >/dev/null 2>&1 || true
    yarn config delete https-proxy >/dev/null 2>&1 || true
  fi
  if command -v pip3 >/dev/null 2>&1; then
    pip3 config unset global.proxy >/dev/null 2>&1 || true
  elif command -v pip >/dev/null 2>&1; then
    pip config unset global.proxy >/dev/null 2>&1 || true
  fi
}
EOF

  cat >> "$BIN_DIR/clash-proxy-lib.sh" <<'EOF'
apply_apt_proxy() {
  local http_url="$1"
  if [ "$OS_NAME" != 'linux' ]; then
    return 0
  fi
  if [ -f "$APT_FILE" ] && grep -Fq "$http_url" "$APT_FILE"; then
    echo 'APT proxy already present'
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo 'APT proxy skipped: sudo unavailable'
    return 0
  fi
  if sudo -n true >/dev/null 2>&1; then
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_url" "$http_url" | sudo tee "$APT_FILE" >/dev/null
    echo "APT proxy written to $APT_FILE"
    return 0
  fi
  if [ -t 0 ]; then
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_url" "$http_url" | sudo tee "$APT_FILE" >/dev/null
    echo "APT proxy written to $APT_FILE"
  else
    echo 'APT proxy skipped: no TTY and sudo needs password'
  fi
}

remove_apt_proxy() {
  if [ "$OS_NAME" != 'linux' ]; then
    return 0
  fi
  if [ -f "$APT_FILE" ] && command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      sudo rm -f "$APT_FILE" >/dev/null 2>&1 || true
    elif [ -t 0 ]; then
      sudo rm -f "$APT_FILE" >/dev/null 2>&1 || true
    else
      echo 'APT proxy file retained: no TTY and sudo needs password'
    fi
  fi
}

launch_clash() {
  if command -v clash-verge >/dev/null 2>&1; then
    if command -v setsid >/dev/null 2>&1; then
      setsid bash -lc 'exec clash-verge >>"$HOME/.local/var/log/clash-verge.log" 2>&1 < /dev/null' &
    else
      nohup bash -lc 'exec clash-verge >>"$HOME/.local/var/log/clash-verge.log" 2>&1 < /dev/null' &
    fi
    return 0
  fi

  if [ "$OS_NAME" = 'darwin' ]; then
    local app_path="${CLASH_PROXY_APP_PATH:-}"
    if [ -z "$app_path" ]; then
      if [ -d "/Applications/Clash Verge.app" ]; then
        app_path="/Applications/Clash Verge.app"
      elif [ -d "$HOME/Applications/Clash Verge.app" ]; then
        app_path="$HOME/Applications/Clash Verge.app"
      fi
    fi
    [ -n "$app_path" ] || return 1
    nohup open "$app_path" >/dev/null 2>&1 &
    return 0
  fi

  return 1
}

wait_for_clash_ready() {
  local i
  for i in $(seq 1 40); do
    if is_clash_running; then
      load_config
      if mixed_port_listening; then
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

start_clash() {
  if [ -f "$VERGE_CFG" ]; then
    if [ "$OS_NAME" = 'darwin' ]; then
      sed -i '' 's/^enable_silent_start: true$/enable_silent_start: false/' "$VERGE_CFG" || true
    else
      sed -i 's/^enable_silent_start: true$/enable_silent_start: false/' "$VERGE_CFG" || true
    fi
  fi
  if is_clash_running; then
    wait_for_clash_ready >/dev/null 2>&1 || true
    echo 'Clash Verge already running'
    return 0
  fi
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  launch_clash || { echo "failed to launch Clash Verge" >&2; return 1; }
  wait_for_clash_ready || { echo "Clash Verge did not stay running" >&2; return 1; }
  echo 'Clash Verge started'
}

stop_clash() {
  local i
  pkill -x clash-verge >/dev/null 2>&1 || true
  pkill -x verge-mihomo >/dev/null 2>&1 || true
  if [ "$OS_NAME" = 'darwin' ]; then
    pkill -f 'Clash Verge' >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 20); do
    if ! is_clash_running; then
      return 0
    fi
    sleep 0.25
  done
}

tool_proxy_value() {
  case "$1" in
    git_http) git config --global --get http.proxy 2>/dev/null || true ;;
    git_https) git config --global --get https.proxy 2>/dev/null || true ;;
    npm_proxy) npm config get proxy 2>/dev/null || true ;;
    npm_https) npm config get https-proxy 2>/dev/null || true ;;
    pnpm_proxy) pnpm config get proxy 2>/dev/null || true ;;
    pnpm_https) pnpm config get https-proxy 2>/dev/null || true ;;
    yarn_proxy) yarn config get proxy 2>/dev/null || true ;;
    yarn_https) yarn config get https-proxy 2>/dev/null || true ;;
    pip_proxy) pip3 config get global.proxy 2>/dev/null || pip config get global.proxy 2>/dev/null || true ;;
    *) return 1 ;;
  esac
}

any_tool_proxy_configured() {
  local key raw
  for key in git_http git_https npm_proxy npm_https pnpm_proxy pnpm_https yarn_proxy yarn_https pip_proxy; do
    raw="$(normalize_value "$(tool_proxy_value "$key")")"
    if [ "$raw" != '<unset>' ]; then
      return 0
    fi
  done
  return 1
}

summary_state() {
  local running='0' envf='0' tools='0'
  is_clash_running && running='1'
  env_file_exists && envf='1'
  any_tool_proxy_configured && tools='1'
  if [ "$running" = '1' ] && [ "$envf" = '1' ] && [ "$tools" = '1' ]; then
    printf '%s' 'enabled'
  elif [ "$running" = '0' ] && [ "$envf" = '0' ] && [ "$tools" = '0' ]; then
    printf '%s' 'disabled'
  else
    printf '%s' 'partial'
  fi
}

compact_effective_proxy_lines() {
  load_config
  if env_file_exists; then
    printf '%-24s%s\n' 'http/https' "$HTTP_URL"
    printf '%-24s%s\n' 'all_proxy(socks5)' "$SOCKS_URL"
  else
    echo '<not enabled>'
  fi
}

compact_tool_proxy_lines() {
  printf '%-24s%s\n' 'git http.proxy' "$(normalize_value "$(tool_proxy_value git_http)")"
  printf '%-24s%s\n' 'git https.proxy' "$(normalize_value "$(tool_proxy_value git_https)")"
  printf '%-24s%s\n' 'npm proxy' "$(normalize_value "$(tool_proxy_value npm_proxy)")"
  printf '%-24s%s\n' 'npm https-proxy' "$(normalize_value "$(tool_proxy_value npm_https)")"
}

compact_port_note() {
  load_config
  printf 'effective listener: mixed-port=%s (handles HTTP and SOCKS5)\n' "$DECLARED_MIXED_PORT"
  local disabled=()
  if ! is_true "$VERGE_SOCKS_ENABLED_RAW"; then disabled+=("dedicated socks=$DECLARED_SOCKS_PORT"); fi
  if ! is_true "$VERGE_HTTP_ENABLED_RAW"; then disabled+=("dedicated http=$DECLARED_HTTP_PORT"); fi
  if ! is_true "$ENABLE_EXTERNAL_CONTROLLER_RAW"; then disabled+=("controller=$CTRL_ADDR"); fi
  if [ ${#disabled[@]} -gt 0 ]; then
    local IFS=', '
    printf 'inactive extras: %s\n' "${disabled[*]}"
  fi
}
EOF

  cat > "$BIN_DIR/clash-proxy-on.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
. "$SCRIPT_DIR/clash-proxy-lib.sh"

start_clash
load_config
write_env_file
apply_tool_proxy "$HTTP_URL"
apply_apt_proxy "$HTTP_URL"

echo '=== RESULT ==='
printf '%-24s%s\n' 'clash' 'running'
printf '%-24s%s\n' 'http/https' "$HTTP_URL"
printf '%-24s%s\n' 'all_proxy(socks5)' "$SOCKS_URL"
printf '%-24s%s\n' 'env file' "$ENV_FILE"
printf '%-24s%s\n' 'state' "$(summary_state)"
echo 'Tip: in interactive bash/zsh, running "proxy on" also syncs the current shell.'
EOF

  cat > "$BIN_DIR/clash-proxy-off.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
. "$SCRIPT_DIR/clash-proxy-lib.sh"

clear_tool_proxy
rm -f "$ENV_FILE"
remove_apt_proxy
stop_clash
# Note: clear_current_shell_env only affects this subprocess;
# the parent shell's env is cleared by the proxy() shell function.

echo '=== RESULT ==='
printf '%-24s%s\n' 'clash' 'stopped'
printf '%-24s%s\n' 'env file' '<removed>'
printf '%-24s%s\n' 'state' "$(summary_state)"
echo 'Proxy environment cleaned.'
EOF

  cat > "$BIN_DIR/clash-proxy-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
. "$SCRIPT_DIR/clash-proxy-lib.sh"

MODE="${1:-}"
load_config

show_value() {
  local label="$1"
  shift
  local raw
  raw="$("$@" 2>/dev/null || true)"
  printf '%-24s%s\n' "$label" "$(normalize_value "$raw")"
}

print_active_ports() {
  local out
  out="$(active_ports_output)"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo '<not listening>'
  fi
}

if [ "$MODE" = '-v' ] || [ "$MODE" = '--verbose' ] || [ "$MODE" = 'verbose' ]; then
  echo '=== SUMMARY ==='
  printf '%-24s%s\n' 'overall' "$(summary_state)"
  printf '%-24s%s\n' 'clash' "$(is_clash_running && echo running || echo stopped)"
  printf '%-24s%s\n' 'env file' "$(env_file_exists && echo present || echo absent)"
  printf '%-24s%s\n' 'current shell env' "$(current_shell_proxy_loaded && echo loaded || echo not-loaded)"
  printf '%-24s%s\n' 'tool config' "$(any_tool_proxy_configured && echo configured || echo clear)"

  echo
  echo '=== PROCESS ==='
  clash_processes

  echo
  echo '=== PORT ==='
  print_active_ports

  echo
  echo '=== CLASH CONFIG ==='
  grep -E '^(redir-port|tproxy-port|mixed-port|socks-port|port|external-controller):' "$CORE_CFG" || true

  echo
  echo '=== VERGE SWITCHES ==='
  grep -E '^(enable_auto_launch|enable_silent_start|enable_system_proxy|enable_tun_mode|enable_external_controller|verge_redir_enabled|verge_tproxy_enabled|verge_socks_enabled|verge_http_enabled):' "$VERGE_CFG" || true

  echo
  echo '=== EFFECTIVE PROXY ==='
  compact_effective_proxy_lines

  echo
  echo '=== ENV FILE ==='
  if env_file_exists; then
    sed -n '1,120p' "$ENV_FILE"
  else
    echo '<not enabled>'
  fi

  echo
  echo '=== CURRENT SHELL ENV ==='
  env | grep -E '^(http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|no_proxy|NO_PROXY)=' | sort || true

  echo
  echo '=== TOOL CONFIG ==='
  show_value 'git http.proxy' git config --global --get http.proxy
  show_value 'git https.proxy' git config --global --get https.proxy
  show_value 'npm proxy' npm config get proxy
  show_value 'npm https-proxy' npm config get https-proxy
  if command -v pnpm >/dev/null 2>&1; then
    show_value 'pnpm proxy' pnpm config get proxy
    show_value 'pnpm https-proxy' pnpm config get https-proxy
  else
    printf '%-24s%s\n' 'pnpm proxy' '<unset>'
    printf '%-24s%s\n' 'pnpm https-proxy' '<unset>'
  fi
  if command -v yarn >/dev/null 2>&1; then
    show_value 'yarn proxy' yarn config get proxy
    show_value 'yarn https-proxy' yarn config get https-proxy
  else
    printf '%-24s%s\n' 'yarn proxy' '<unset>'
    printf '%-24s%s\n' 'yarn https-proxy' '<unset>'
  fi
  if command -v pip3 >/dev/null 2>&1; then
    show_value 'pip global.proxy' pip3 config get global.proxy
  elif command -v pip >/dev/null 2>&1; then
    show_value 'pip global.proxy' pip config get global.proxy
  else
    printf '%-24s%s\n' 'pip global.proxy' '<unset>'
  fi

  echo
  echo '=== APT PROXY ==='
  if [ -f "$APT_FILE" ]; then
    sed -n '1,20p' "$APT_FILE"
  else
    echo '<unset>'
  fi

  echo
  echo '=== SHELL INTEGRATION ==='
  if grep -q 'proxy-suite env' "$HOME/.bashrc" 2>/dev/null || grep -q 'proxy-suite env' "$HOME/.zshrc" 2>/dev/null; then
    echo 'ready'
  else
    echo 'incomplete'
  fi
  exit 0
fi

echo '=== SUMMARY ==='
printf '%-24s%s\n' 'overall' "$(summary_state)"
printf '%-24s%s\n' 'clash' "$(is_clash_running && echo running || echo stopped)"
printf '%-24s%s\n' 'env file' "$(env_file_exists && echo present || echo absent)"
printf '%-24s%s\n' 'current shell env' "$(current_shell_proxy_loaded && echo loaded || echo not-loaded)"
printf '%-24s%s\n' 'tool config' "$(any_tool_proxy_configured && echo configured || echo clear)"

echo
echo '=== ACTIVE PORTS ==='
print_active_ports

echo
echo '=== EFFECTIVE PROXY ==='
compact_effective_proxy_lines

echo
echo '=== TOOL PROXY ==='
compact_tool_proxy_lines

echo
echo '=== NOTE ==='
compact_port_note
echo 'Daily flow: proxy on -> proxy test -> proxy off; use "proxy status -v" for troubleshooting.'
EOF

  cat > "$BIN_DIR/clash-proxy-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
. "$SCRIPT_DIR/clash-proxy-lib.sh"

TEST_URL="${1:-https://api.github.com/meta}"
load_config

ok() { echo "[OK] $*"; }
fail() { echo "[FAIL] $*" >&2; }
skip() { echo "[SKIP] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { fail "missing command: $1"; return 1; }
}

http_check() {
  local name="$1"
  shift
  local code
  code="$("$@" 2>/dev/null || true)"
  case "$code" in
    2*|3*) ok "$name -> HTTP $code"; return 0 ;;
    *) fail "$name failed (HTTP=$code)"; return 1 ;;
  esac
}

EXIT_CODE=0
require_cmd curl

echo '=== SUMMARY ==='
printf '%-24s%s\n' 'target' "$TEST_URL"
printf '%-24s%s\n' 'overall(before test)' "$(summary_state)"

echo
echo '=== PROCESS ==='
if is_clash_running; then
  clash_processes
  ok 'Clash process present'
else
  fail 'Clash process is not running; run "proxy on" first'
  EXIT_CODE=1
fi

echo
echo '=== PORT ==='
if mixed_port_listening; then
  active_ports_output | grep "127.0.0.1:${DECLARED_MIXED_PORT}" || true
  ok "mixed-port ${DECLARED_MIXED_PORT} is listening"
else
  fail "mixed-port ${DECLARED_MIXED_PORT} is not listening"
  EXIT_CODE=1
fi

echo
echo '=== CONTROLLER ==='
if controller_listening; then
  http_check "controller ${CTRL_ADDR}" curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "http://${CTRL_ADDR}/version" || EXIT_CODE=1
else
  skip "controller ${CTRL_ADDR} is not listening"
fi

echo
echo '=== OUTBOUND TEST ==='
http_check 'HTTP proxy egress' curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 -x "$HTTP_URL" "$TEST_URL" || EXIT_CODE=1
http_check 'SOCKS5(mixed-port) egress' curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 --socks5-hostname "$HOST:$DECLARED_MIXED_PORT" "$TEST_URL" || EXIT_CODE=1

echo
echo '=== ENV FILE ==='
if env_file_exists; then
  ok 'Proxy env file exists'
else
  fail 'Proxy env file is missing'
  EXIT_CODE=1
fi

if current_shell_proxy_loaded; then
  ok 'Current shell already has proxy env loaded'
else
  skip 'Current shell env not loaded; this is expected in non-interactive shells'
fi

exit "$EXIT_CODE"
EOF

  cat > "$BIN_DIR/proxy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

case "${1:-}" in
  on) exec "$SCRIPT_DIR/clash-proxy-on.sh" "${@:2}" ;;
  off) exec "$SCRIPT_DIR/clash-proxy-off.sh" "${@:2}" ;;
  status) exec "$SCRIPT_DIR/clash-proxy-status.sh" "${@:2}" ;;
  test) exec "$SCRIPT_DIR/clash-proxy-test.sh" "${@:2}" ;;
  update)
    STATE_DIR="${STATE_DIR:-$HOME/.local/share/proxy-suite-installer}"
    META_FILE="$STATE_DIR/install-meta.env"
    if [ -f "$META_FILE" ]; then
      # shellcheck disable=SC1090
      . "$META_FILE"
    fi
    INSTALL_SRC="${CLASH_PROXY_INSTALL_SRC:-}"
    INSTALL_URL="${CLASH_PROXY_INSTALL_URL:-}"
    if [ -n "$INSTALL_SRC" ] && [ -f "$INSTALL_SRC" ]; then
      exec bash "$INSTALL_SRC" --skip-clash-install "${@:2}"
    elif [ -n "$INSTALL_URL" ]; then
      echo "Updating from $INSTALL_URL ..." >&2
      local tmp_update
      tmp_update="$(mktemp)"
      if ! curl --proto '=https' -fsSL "$INSTALL_URL" -o "$tmp_update"; then
        rm -f "$tmp_update"
        echo "Failed to download update script from $INSTALL_URL" >&2
        exit 1
      fi
      exec bash "$tmp_update" --skip-clash-install "${@:2}"
    else
      echo "Re-run the original install.sh with --skip-clash-install to refresh commands." >&2
      exit 1
    fi
    ;;
  uninstall) exec "$SCRIPT_DIR/proxy-uninstall" "${@:2}" ;;
  ""|-h|--help|help)
    cat <<'HELP'
Usage: proxy <on|off|status|test|update|uninstall>
  proxy on                  start Clash Verge and enable shell/tool proxy
  proxy off                 stop Clash Verge and clear shell/tool proxy
  proxy status              show compact daily status
  proxy status -v           show verbose diagnostic status
  proxy test [URL]          validate local ports and outbound proxy egress
  proxy update              re-run installer to refresh the command suite
  proxy uninstall           remove the local proxy command suite

Examples:
  proxy on
  proxy test
  proxy status
  proxy status -v
  proxy off
  proxy update
  proxy uninstall
HELP
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    echo "usage: proxy <on|off|status|test|update|uninstall>" >&2
    exit 1
    ;;
esac
EOF

  cat > "$BIN_DIR/proxy-uninstall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/proxy-suite-installer}"
META_FILE="$STATE_DIR/install-meta.env"
SHELL_LIST_FILE="$STATE_DIR/managed-shell-files.txt"
ENV_FILE="${ENV_FILE:-$HOME/.config/clash-proxy.env}"
LOG_FILE="${LOG_FILE:-$HOME/.local/var/log/clash-verge.log}"
YES=0
REMOVE_CONFIG=0
REMOVE_APP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ; shift ;;
    --purge-config) REMOVE_CONFIG=1 ; shift ;;
    --remove-app) REMOVE_APP=1 ; shift ;;
    -h|--help)
      cat <<'HELP'
Usage: proxy-uninstall [--yes] [--purge-config] [--remove-app]

Without flags, proxy-uninstall runs in interactive mode and asks for confirmation.
HELP
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -f "$META_FILE" ]; then
  # shellcheck disable=SC1090
  . "$META_FILE"
fi

confirm() {
  local prompt="$1"
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  local answer
  read -r -p "$prompt [y/N] " answer
  case "$answer" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

remove_managed_block() {
  local file="$1"
  local marker="$2"
  local start end tmp

  [ -f "$file" ] || return 0
  start="# >>> ${marker} >>>"
  end="# <<< ${marker} <<<"
  tmp="$(mktemp)"

  awk -v start="$start" -v end="$end" '
    BEGIN { skip = 0 }
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"

  if [ -s "$tmp" ]; then
    awk '
      { lines[NR] = $0 }
      END {
        last = NR
        while (last > 0 && lines[last] == "") {
          last--
        }
        for (i = 1; i <= last; i++) {
          print lines[i]
        }
        print ""
      }
    ' "$tmp" > "$file"
  else
    : > "$file"
  fi

  rm -f "$tmp"
}

remove_rc_blocks() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    remove_managed_block "$file" "proxy-suite env"
    remove_managed_block "$file" "proxy-suite user bin path"
    remove_managed_block "$file" "proxy-suite shell function"
  done < <(
    {
      [ -f "$SHELL_LIST_FILE" ] && cat "$SHELL_LIST_FILE"
      printf '%s\n' "$HOME/.bashrc" "$HOME/.zshrc"
    } | awk 'NF && !seen[$0]++'
  )
}

remove_app_install() {
  local removed='no'
  case "${CLASH_PROXY_OS:-}" in
    linux)
      if command -v apt-get >/dev/null 2>&1 && dpkg -s clash-verge >/dev/null 2>&1; then
        sudo apt-get purge -y clash-verge
        sudo apt-get autoremove --purge -y
        removed='yes'
      elif command -v dnf >/dev/null 2>&1 && rpm -q clash-verge >/dev/null 2>&1; then
        sudo dnf remove -y clash-verge
        removed='yes'
      elif command -v rpm >/dev/null 2>&1 && rpm -q clash-verge >/dev/null 2>&1; then
        sudo rpm -e clash-verge
        removed='yes'
      fi
      ;;
    darwin)
      local app_path="${CLASH_PROXY_APP_PATH:-}"
      [ -z "$app_path" ] && [ -d "/Applications/Clash Verge.app" ] && app_path="/Applications/Clash Verge.app"
      [ -z "$app_path" ] && [ -d "$HOME/Applications/Clash Verge.app" ] && app_path="$HOME/Applications/Clash Verge.app"
      if [ -n "$app_path" ] && [ -e "$app_path" ]; then
        rm -rf "$app_path"
        removed='yes'
      fi
      ;;
  esac
  printf '%s' "$removed"
}

cleanup_suite_files() {
  rm -f "$ENV_FILE" "$LOG_FILE"
  rm -f \
    "$SCRIPT_DIR/proxy" \
    "$SCRIPT_DIR/proxy-uninstall" \
    "$SCRIPT_DIR/clash-proxy-lib.sh" \
    "$SCRIPT_DIR/clash-proxy-on.sh" \
    "$SCRIPT_DIR/clash-proxy-off.sh" \
    "$SCRIPT_DIR/clash-proxy-status.sh" \
    "$SCRIPT_DIR/clash-proxy-test.sh"
}

echo 'This will remove the local proxy command suite, shell integration, and runtime files.'
confirm 'Continue uninstall?' || { echo 'Cancelled.'; exit 0; }

if [ "$REMOVE_CONFIG" -eq 0 ] && confirm 'Also delete Clash Verge user config and local data?'; then
  REMOVE_CONFIG=1
fi

if [ "$REMOVE_APP" -eq 0 ] && confirm 'Also attempt to remove the Clash Verge application/package?'; then
  REMOVE_APP=1
fi

if [ -x "$SCRIPT_DIR/clash-proxy-off.sh" ]; then
  "$SCRIPT_DIR/clash-proxy-off.sh" >/dev/null 2>&1 || true
fi

remove_rc_blocks

config_removed='no'
if [ "$REMOVE_CONFIG" -eq 1 ]; then
  rm -rf \
    "$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev" \
    "$HOME/.cache/clash-verge" \
    "$HOME/.config/clash-verge"
  config_removed='yes'
fi

app_removed='no'
if [ "$REMOVE_APP" -eq 1 ]; then
  if command -v sudo >/dev/null 2>&1 && ! sudo -n true >/dev/null 2>&1; then
    sudo -v
  fi
  app_removed="$(remove_app_install)"
fi

rm -rf "$STATE_DIR"
cleanup_suite_files

echo '=== RESULT ==='
printf '%-24s%s\n' 'suite commands' 'removed'
printf '%-24s%s\n' 'shell integration' 'removed'
printf '%-24s%s\n' 'user config data' "$config_removed"
printf '%-24s%s\n' 'application/package' "$app_removed"
printf '%-24s%s\n' 'env/log/state' 'removed'
EOF

  chmod +x \
    "$BIN_DIR/clash-proxy-lib.sh" \
    "$BIN_DIR/clash-proxy-on.sh" \
    "$BIN_DIR/clash-proxy-off.sh" \
    "$BIN_DIR/clash-proxy-status.sh" \
    "$BIN_DIR/clash-proxy-test.sh" \
    "$BIN_DIR/proxy" \
    "$BIN_DIR/proxy-uninstall"
}

configure_shell_files() {
  local rc_file env_block path_block fn_block
  local seen_files=''
  PATCHED_SHELL_FILES=""

  env_block=$(cat <<'EOF'
[ -f "$HOME/.config/clash-proxy.env" ] && . "$HOME/.config/clash-proxy.env"
EOF
)

  path_block=$(cat <<'EOF'
case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) export PATH="$HOME/bin:$PATH" ;;
esac
EOF
)

  fn_block=$(cat <<'EOF'
proxy() {
  case "${1:-}" in
    on)
      command proxy on "${@:2}"
      local rc
      rc=$?
      if [ $rc -eq 0 ] && [ -f "$HOME/.config/clash-proxy.env" ]; then
        . "$HOME/.config/clash-proxy.env"
      fi
      return $rc
      ;;
    off)
      command proxy off "${@:2}"
      local rc
      rc=$?
      unset CLASH_PROXY_HOST CLASH_PROXY_PORT CLASH_HTTP_PROXY_URL CLASH_SOCKS_PROXY_URL CLASH_CONTROLLER_ADDR
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
      return $rc
      ;;
    *)
      command proxy "$@"
      ;;
  esac
}
EOF
)

  while IFS= read -r rc_file; do
    [ -n "$rc_file" ] || continue
    case ":$seen_files:" in
      *":$rc_file:"*) continue ;;
    esac
    seen_files="${seen_files}:$rc_file:"
    replace_managed_block "$rc_file" "proxy-suite env" "$env_block"
    replace_managed_block "$rc_file" "proxy-suite user bin path" "$path_block"
    replace_managed_block "$rc_file" "proxy-suite shell function" "$fn_block"
    PATCHED_SHELL_FILES="${PATCHED_SHELL_FILES}${rc_file}"$'\n'
  done < <(determine_shell_files)
}

write_meta_file() {
  local os="$1"
  local arch="$2"
  local clash_version="$3"
  local package_family="$4"
  local app_path="$5"
  local program_managed="$6"
  local app_dir

  mkdir -p "$STATE_DIR"
  case "$os" in
    linux) app_dir="$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev" ;;
    darwin) app_dir="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ;;
    *) app_dir="" ;;
  esac

  cat > "$STATE_DIR/install-meta.env" <<EOF
PROXY_SUITE_VERSION="$PROXY_SUITE_VERSION"
CLASH_PROXY_OS="$os"
CLASH_PROXY_ARCH="$arch"
CLASH_PROXY_VERSION="$clash_version"
CLASH_PROXY_PACKAGE_FAMILY="$package_family"
CLASH_PROXY_APP_DIR="$app_dir"
CLASH_PROXY_APP_PATH="$app_path"
CLASH_PROXY_PROGRAM_MANAGED="$program_managed"
CLASH_PROXY_BIN_DIR="$BIN_DIR"
CLASH_PROXY_INSTALL_SRC="${SCRIPT_DIR:+$(cd "$SCRIPT_DIR" && pwd -P)/install.sh}"
CLASH_PROXY_INSTALL_URL="$INSTALL_REMOTE_URL"
EOF

  printf '%s' "$PATCHED_SHELL_FILES" > "$STATE_DIR/managed-shell-files.txt"
}

validate_generated_files() {
  local file
  for file in \
    ${SCRIPT_DIR:+"$SCRIPT_DIR/install.sh"} \
    "$BIN_DIR/clash-proxy-lib.sh" \
    "$BIN_DIR/clash-proxy-on.sh" \
    "$BIN_DIR/clash-proxy-off.sh" \
    "$BIN_DIR/clash-proxy-status.sh" \
    "$BIN_DIR/clash-proxy-test.sh" \
    "$BIN_DIR/proxy" \
    "$BIN_DIR/proxy-uninstall"; do
    bash -n "$file"
  done
}

main() {
  local os arch clash_version package_family app_path program_managed clash_action

  need_cmd bash
  need_cmd sed
  need_cmd grep
  need_cmd awk
  need_cmd cut

  os="$(detect_os)"
  arch="$(normalize_arch)"
  clash_version="$(resolve_clash_version)"
  package_family='skip'
  app_path=''
  program_managed='0'
  clash_action='skipped-command-suite-only'

  mktemp_dir

  if [ "$SKIP_CLASH_INSTALL" -eq 0 ]; then
    if [ "$os" = 'linux' ]; then
      package_family="$(detect_pkg_family)"
      install_clash_linux "$clash_version" "$arch"
      clash_action="${CLASH_INSTALL_ACTION:-installed-or-updated}"
      install_linux_fonts
      app_path="$(command -v clash-verge || true)"
    else
      package_family='dmg'
      install_clash_macos "$clash_version" "$arch"
      clash_action="${CLASH_INSTALL_ACTION:-installed-or-updated}"
      app_path="$(cat "$TMP_DIR/macos_app_path")"
    fi
    program_managed='1'
  else
    if [ "$os" = 'linux' ]; then
      package_family="$(detect_pkg_family)"
      app_path="$(command -v clash-verge || true)"
    else
      package_family='dmg'
      if [ -d "/Applications/Clash Verge.app" ]; then
        app_path="/Applications/Clash Verge.app"
      elif [ -d "$HOME/Applications/Clash Verge.app" ]; then
        app_path="$HOME/Applications/Clash Verge.app"
      fi
    fi
  fi

  write_proxy_files
  if [ "$NO_MODIFY_SHELL" -eq 0 ]; then
    configure_shell_files
  else
    PATCHED_SHELL_FILES='<skipped>'
  fi
  write_meta_file "$os" "$arch" "$clash_version" "$package_family" "$app_path" "$program_managed"
  validate_generated_files

  echo '=== INSTALL RESULT ==='
  printf '%-24s%s\n' 'proxy suite version' "$PROXY_SUITE_VERSION"
  printf '%-24s%s\n' 'platform' "$os/$arch"
  printf '%-24s%s\n' 'clash version' "$clash_version"
  printf '%-24s%s\n' 'clash install' "$clash_action"
  printf '%-24s%s\n' 'bin dir' "$BIN_DIR"
  printf '%-24s%s\n' 'state dir' "$STATE_DIR"
  printf '%-24s%s\n' 'shell files' "$(printf '%s' "$PATCHED_SHELL_FILES" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo
  echo 'Next steps:'
  if [ "$NO_MODIFY_SHELL" -eq 0 ]; then
    echo '  1. Open a new shell, or run: source ~/.bashrc'
    echo '  2. Run: proxy on'
    echo '  3. Run: proxy test'
    echo '  4. Run: proxy status'
  else
    echo "  1. Add $BIN_DIR to your PATH and load ~/.config/clash-proxy.env manually when needed"
    echo "  2. Run: $BIN_DIR/proxy on"
    echo "  3. Run: $BIN_DIR/proxy test"
    echo "  4. Run: $BIN_DIR/proxy status"
  fi
}

main "$@"
