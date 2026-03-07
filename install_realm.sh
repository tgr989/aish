#!/usr/bin/env bash
set -euo pipefail

# English-only logs/comments as requested by your general style preferences.
log() { echo "[realm-installer] $*" >&2; }
die() { echo "[realm-installer][ERROR] $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo ./install_realm.sh install [options]
  sudo ./install_realm.sh uninstall

Options:
  --listen   IP:PORT        Listener address (default 0.0.0.0)
  --udp      true|false     Enable UDP (default true)
  --no-tcp   true|false     Disable TCP (default false)
  --endpoint LISTEN REMOTE  Add one endpoint mapping. Repeatable.
                            LISTEN example: 0.0.0.0:23456
                            REMOTE example: test.cloudflare.com:23456

  --config   /path/file     Config path (default /etc/realm/config.toml)
  --bin-dir  /path          Install dir (default /usr/local/bin)
  --service  name           systemd service name (default realm)
  --version  vX.Y.Z         Pin a specific version (default: latest release)
  --musl     auto|true|false  Prefer musl build (default auto)

Examples:
  sudo ./install_realm.sh install \
    --endpoint 0.0.0.0:23456 test.cloudflare.com:23456 \
    --endpoint 0.0.0.0:54321 1.1.1.1:443

  sudo ./install_realm.sh uninstall
EOF
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run as root (use sudo)."
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7" ;;
    i686|i386) echo "i686" ;;
    *) die "Unsupported arch: $arch" ;;
  esac
}

detect_musl() {
  # Return 0 if musl, 1 if glibc (or unknown -> assume glibc)
  if ldd --version 2>&1 | grep -qi musl; then
    return 0
  fi
  return 1
}

github_latest_tag() {
  # Use GitHub API to fetch latest tag. No jq dependency.
  # Output example: v2.4.6
  local api="https://api.github.com/repos/zhboner/realm/releases/latest"
  local json
  json="$(curl -fsSL "$api")" || die "Failed to query GitHub API: $api"
  echo "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

download_realm() {
  local version="$1" arch="$2" prefer_musl="$3" bin_dir="$4"
  local triple suffix url tmpdir tarball

  suffix="unknown-linux-gnu"
  if [[ "$prefer_musl" == "true" ]]; then
    suffix="unknown-linux-musl"
  elif [[ "$prefer_musl" == "auto" ]]; then
    if detect_musl; then suffix="unknown-linux-musl"; fi
  fi

  triple="realm-${arch}-${suffix}"
  tarball="${triple}.tar.gz"
  url="https://github.com/zhboner/realm/releases/download/${version}/${tarball}"

  tmpdir="$(mktemp -d)"
  trap '[[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir"' RETURN

  log "Downloading Realm: ${url}"
  curl -fL --retry 3 --retry-delay 1 -o "${tmpdir}/${tarball}" "$url" \
    || die "Download failed: $url"

  log "Extracting..."
  tar -C "$tmpdir" -zxf "${tmpdir}/${tarball}" || die "Failed to extract tarball"

  [[ -f "${tmpdir}/realm" ]] || die "Binary 'realm' not found in tarball"
  install -m 0755 "${tmpdir}/realm" "${bin_dir}/realm"

  log "Installed binary: ${bin_dir}/realm"
}

write_config() {
  local config_path="$1" use_udp="$2" no_tcp="$3"
  shift 3
  local endpoints=("$@")

  mkdir -p "$(dirname "$config_path")"

  # endpoints array stores pairs: listen remote listen remote ...
  if (( ${#endpoints[@]} == 0 )); then
    die "No endpoints provided. Use --endpoint LISTEN REMOTE (repeatable)."
  fi
  if (( ${#endpoints[@]} % 2 != 0 )); then
    die "Endpoint arguments must be LISTEN REMOTE pairs."
  fi

  log "Writing config: $config_path"
  {
    echo "[network]"
    echo "no_tcp = ${no_tcp}"
    echo "use_udp = ${use_udp}"
    echo
    local i=0
    while (( i < ${#endpoints[@]} )); do
      local listen="${endpoints[i]}"
      local remote="${endpoints[i+1]}"
      echo "[[endpoints]]"
      echo "listen = \"${listen}\""
      echo "remote = \"${remote}\""
      echo
      i=$((i+2))
    done
  } > "$config_path"
}

write_service() {
  local service_name="$1" bin_dir="$2" config_path="$3"
  local unit_path="/etc/systemd/system/${service_name}.service"

  log "Writing systemd unit: $unit_path"
  cat > "$unit_path" <<EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${bin_dir}/realm -c ${config_path}

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  local service_name="$1"
  log "Enabling and starting service: ${service_name}"
  systemctl daemon-reload
  systemctl enable --now "${service_name}"
  systemctl --no-pager --full status "${service_name}" || true
}

uninstall_all() {
  local service_name="${1:-realm}"
  local bin_dir="${2:-/usr/local/bin}"
  local config_path="${3:-/etc/realm/config.toml}"

  log "Stopping service (if exists): ${service_name}"
  systemctl stop "${service_name}" >/dev/null 2>&1 || true
  systemctl disable "${service_name}" >/dev/null 2>&1 || true

  local unit_path="/etc/systemd/system/${service_name}.service"
  if [[ -f "$unit_path" ]]; then
    rm -f "$unit_path"
    log "Removed unit: $unit_path"
  fi

  systemctl daemon-reload || true

  if [[ -f "${bin_dir}/realm" ]]; then
    rm -f "${bin_dir}/realm"
    log "Removed binary: ${bin_dir}/realm"
  fi

  if [[ -f "$config_path" ]]; then
    rm -f "$config_path"
    log "Removed config: $config_path"
  fi

  # Keep /etc/realm directory if not empty.
  log "Uninstall complete."
}

main() {
  if (( $# < 1 )); then usage; exit 1; fi

  local action="$1"; shift || true

  local listen_ip="0.0.0.0"
  local use_udp="true"
  local no_tcp="false"
  local config_path="/etc/realm/config.toml"
  local bin_dir="/usr/local/bin"
  local service_name="realm"
  local version=""
  local musl_pref="auto"
  local endpoints=()

  while (( $# )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --listen) listen_ip="$2"; shift 2 ;;
      --udp) use_udp="$2"; shift 2 ;;
      --no-tcp) no_tcp="$2"; shift 2 ;;
      --endpoint)
        endpoints+=("$2" "$3")
        shift 3
        ;;
      --config) config_path="$2"; shift 2 ;;
      --bin-dir) bin_dir="$2"; shift 2 ;;
      --service) service_name="$2"; shift 2 ;;
      --version) version="$2"; shift 2 ;;
      --musl) musl_pref="$2"; shift 2 ;;
      *)
        die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done

  case "$action" in
    install)
      require_root
      need_cmd uname
      need_cmd tar
      need_cmd install
      need_cmd systemctl
      need_cmd curl
      mkdir -p "$bin_dir"

      local arch
      arch="$(detect_arch)"

      if [[ -z "$version" ]]; then
        version="$(github_latest_tag)"
        [[ -n "$version" ]] || die "Failed to detect latest version"
      fi

      log "Using version: $version"
      log "Arch: $arch, musl preference: $musl_pref"

      download_realm "$version" "$arch" "$musl_pref" "$bin_dir"

      # If user provided endpoints without explicit IP, allow shorthand ":PORT"
      # But here we keep it simple: user supplies full LISTEN.
      write_config "$config_path" "$use_udp" "$no_tcp" "${endpoints[@]}"

      write_service "$service_name" "$bin_dir" "$config_path"
      enable_service "$service_name"

      log "Done."
      log "Logs: journalctl -u ${service_name} -f"
      ;;
    uninstall)
      require_root
      uninstall_all "$service_name" "$bin_dir" "$config_path"
      ;;
    *)
      usage
      die "Unknown action: $action"
      ;;
  esac
}

main "$@"
