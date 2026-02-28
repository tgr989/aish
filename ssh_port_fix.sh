#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Args
# -----------------------------
PORT_DEFAULT="34253"
PORT="$PORT_DEFAULT"
DRY_RUN=false
DO_RELOAD=false
DO_PROCESS_D=false
ONLY_D=false

usage() {
  cat <<'EOF'
Usage:
  ssh_port_fix.sh [--port <1-65535>] [--dry-run] [--reload|--no-reload]

Examples:
  # Default port (34253)
  sudo bash ssh_port_fix.sh

  # Custom port
  sudo bash ssh_port_fix.sh --port 2222

  # Dry run (no changes)
  sudo bash ssh_port_fix.sh --dry-run --port 34253

  # Apply and reload sshd automatically
  sudo bash ssh_port_fix.sh --port 34253 --reload

  # Remote run with args
  curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/ssh_port_fix.sh | sudo bash -s -- --port 34253 --reload
  # Process files under /etc/ssh/sshd_config.d/ (disabled by default)
  curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/ssh_port_fix.sh | sudo bash -s -- --port 34253 --with-sshd-config-d --reload
  # Only process files under /etc/ssh/sshd_config.d/ (will skip /etc/ssh/sshd_config)
  curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/ssh_port_fix.sh | sudo bash -s -- --port 34253 --only-sshd-config-d --reload
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port|-p)
      PORT="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --reload)
      DO_RELOAD=true
      shift
      ;;
    --with-sshd-config-d)
      DO_PROCESS_D=true
      shift
      ;;
    --only-sshd-config-d)
      ONLY_D=true
      DO_PROCESS_D=true
      shift
      ;;
    --no-reload)
      DO_RELOAD=false
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${PORT:-}" ]] || [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "ERROR: invalid port: '${PORT:-}' (must be 1-65535)"
  exit 1
fi

FIXED_PORT="$PORT"

SERVER_MAIN="/etc/ssh/sshd_config"
SERVER_D_GLOB="/etc/ssh/sshd_config.d"/*.conf

timestamp() { date +"%Y%m%d-%H%M%S"; }

# -----------------------------
# Summary helpers
# -----------------------------
declare -a SUMMARY=()
record_summary() {
  local status="$1" file="$2" before="$3" after="$4" note="${5:-}"
  SUMMARY+=("${status}|${file}|${before}|${after}|${note}")
}

print_summary() {
  echo "==================== Summary ===================="

  local max_status=6 max_file=4 max_before=6 max_after=5 max_note=4
  local line status file before after note
  for line in "${SUMMARY[@]}"; do
    IFS='|' read -r status file before after note <<<"$line"
    (( ${#status} > max_status )) && max_status=${#status}
    (( ${#file} > max_file )) && max_file=${#file}
    (( ${#before} > max_before )) && max_before=${#before}
    (( ${#after} > max_after )) && max_after=${#after}
    (( ${#note} > max_note )) && max_note=${#note}
  done

  # Caps to avoid excessively wide output
  (( max_file > 80 )) && max_file=80
  (( max_note > 60 )) && max_note=60

  printf "%-${max_status}s | %-""${max_file}""s | %-""${max_before}""s | %-""${max_after}""s | %s\n" \
    "Status" "File" "Before" "After" "Note"

  # separator line
  local sep
  sep="$(printf '%*s' "$max_status" '' | tr ' ' '-')"
  sep+="-+-"
  sep+="$(printf '%*s' "$max_file" '' | tr ' ' '-')"
  sep+="-+-"
  sep+="$(printf '%*s' "$max_before" '' | tr ' ' '-')"
  sep+="-+-"
  sep+="$(printf '%*s' "$max_after" '' | tr ' ' '-')"
  sep+="-+-"
  sep+="$(printf '%*s' "$max_note" '' | tr ' ' '-')"
  echo "$sep"

  for line in "${SUMMARY[@]}"; do
    IFS='|' read -r status file before after note <<<"$line"
    local file_display="$file" note_display="$note"
    if (( ${#file_display} > max_file )); then
      local trunc_len=$((max_file-3))
      file_display="${file_display:0:trunc_len}..."
    fi
    if (( ${#note_display} > max_note )); then
      local trunc_len2=$((max_note-3))
      note_display="${note_display:0:trunc_len2}..."
    fi
    printf "%-${max_status}s | %-""${max_file}""s | %-""${max_before}""s | %-""${max_after}""s | %s\n" \
      "$status" "$file_display" "$before" "$after" "$note_display"
  done

  echo "================================================="
}

# -----------------------------
# Backup / rollback
# -----------------------------
declare -A BACKUPS=()

backup_file() {
  local f="$1"
  local bak="${f}.bak-$(timestamp)"
  cp -a -- "$f" "$bak"
  BACKUPS["$f"]="$bak"
}

restore_backups() {
  local f
  for f in "${!BACKUPS[@]}"; do
    local bak="${BACKUPS[$f]}"
    if [[ -f "$bak" ]]; then
      cp -a -- "$bak" "$f"
      record_summary "rollback" "$f" "-" "-" "restored from $bak"
    else
      record_summary "rollback" "$f" "-" "-" "backup missing: $bak"
    fi
  done
}

# -----------------------------
# Parsing helpers
# -----------------------------
get_active_ports_csv() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return 0; }

  grep -Eo '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" \
    | awk '{print $2}' \
    | sort -n \
    | uniq \
    | paste -sd, - || true
}

has_active_port_line() {
  local f="$1"
  grep -Eq '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f"
}

count_active_port_lines() {
  local f="$1"
  grep -Ec '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" || true
}

ensure_trailing_newline() {
  local f="$1"
  if [[ -s "$f" ]]; then
    local lastchar
    lastchar="$(tail -c 1 "$f" || true)"
    [[ "$lastchar" == $'\n' ]] || printf '\n' >> "$f"
  fi
}

dedup_fixed_port_lines_keep_last() {
  local f="$1"
  local tmp last
  tmp="$(mktemp)"

  last="$(awk -v p="$FIXED_PORT" '
    $0 ~ "^[[:space:]]*Port[[:space:]]+" p "([[:space:]]+|$)" { last=NR }
    END { if (last=="") last=0; print last }
  ' "$f")"

  awk -v p="$FIXED_PORT" -v last="$last" '
    {
      ismatch = ($0 ~ "^[[:space:]]*Port[[:space:]]+" p "([[:space:]]+|$)")
      if (!ismatch) { print; next }
      if (NR == last) { print; next }
    }
  ' "$f" > "$tmp"

  cat "$tmp" > "$f"
  rm -f "$tmp"
}

sshd_effective_ports_csv() {
  if ! command -v sshd >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  (sshd -T 2>/dev/null || true) | awk 'tolower($1)=="port"{print $2}' | paste -sd, - || true
}

record_sshd_effective_ports() {
  local phase="$1"
  local ports
  ports="$(sshd_effective_ports_csv)"
  if [[ -z "${ports:-}" ]]; then
    record_summary "check" "sshd -T port" "-" "-" "${phase}: unavailable"
  else
    record_summary "check" "sshd -T port" "-" "-" "${phase}: ${ports}"
  fi
}

check_port_available_or_exit() {
  local p="$1"

  if command -v ss >/dev/null 2>&1; then
    local detail
    detail="$(ss -H -lntp "sport = :$p" 2>/dev/null || true)"
    if [[ -n "$detail" ]]; then
      record_summary "check" "port $p" "-" "-" "IN USE (tcp listen). ${detail}"
      echo "ERROR: TCP port $p is already in use (LISTEN). Aborting."
      echo
      print_summary
      exit 3
    fi
    record_summary "check" "port $p" "-" "-" "free (tcp listen)"
    return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)$p$"; then
      record_summary "check" "port $p" "-" "-" "IN USE (tcp listen) via netstat"
      echo "ERROR: TCP port $p is already in use (LISTEN). Aborting."
      echo
      print_summary
      exit 3
    fi
    record_summary "check" "port $p" "-" "-" "free (tcp listen) via netstat"
    return 0
  fi

  record_summary "check" "port $p" "-" "-" "skipped (no ss/netstat)"
}

# -----------------------------
# Core change function
# -----------------------------
replace_or_append_port_in_file() {
  local f="$1"

  if [[ ! -f "$f" ]]; then
    record_summary "skip" "$f" "-" "-" "not found"
    return 0
  fi

  local before_ports before_count after_ports after_count note status
  before_ports="$(get_active_ports_csv "$f")"
  before_count="$(count_active_port_lines "$f")"

  if has_active_port_line "$f"; then
    if [[ "$DRY_RUN" == true ]]; then
      # 预测 after：会变成目标端口且去重后只有一个
      after_ports="$FIXED_PORT"
      status="would-change"
      note="set to ${FIXED_PORT}; dedup(keep last) if multiple"
      if [[ "${before_ports:-}" == "$FIXED_PORT" && "$before_count" -eq 1 ]]; then
        status="would-keep"
        note="already ${FIXED_PORT}"
      fi
      record_summary "$status" "$f" "${before_ports:-<none>}" "${after_ports:-<none>}" "$note"
      return 0
    fi

    backup_file "$f"

    sed -Ei "s/^([[:space:]]*Port[[:space:]]+)[0-9]+/\\1${FIXED_PORT}/" "$f"
    dedup_fixed_port_lines_keep_last "$f"

    after_ports="$(get_active_ports_csv "$f")"
    after_count="$(count_active_port_lines "$f")"

    note="set to ${FIXED_PORT}"
    status="changed"
    if [[ "$before_count" -gt 1 && "$after_count" -eq 1 ]]; then
      note+="; dedup(keep last)"
    fi
    if [[ "${before_ports:-}" == "$FIXED_PORT" && "$before_count" -eq 1 ]]; then
      status="unchanged"
      note="already ${FIXED_PORT}"
    fi

    record_summary "$status" "$f" "${before_ports:-<none>}" "${after_ports:-<none>}" "$note"
    return 0
  fi

  # 没有有效 Port 行 -> 追加
  if [[ "$DRY_RUN" == true ]]; then
    record_summary "would-add" "$f" "<none>" "$FIXED_PORT" "append Port ${FIXED_PORT}"
    return 0
  fi

  backup_file "$f"
  ensure_trailing_newline "$f"
  printf 'Port %s\n' "$FIXED_PORT" >> "$f"

  after_ports="$(get_active_ports_csv "$f")"
  record_summary "added" "$f" "<none>" "${after_ports:-<none>}" "appended Port ${FIXED_PORT}"
}

assert_effective_port_or_rollback() {
  local ports
  ports="$(sshd_effective_ports_csv)"

  if [[ -z "${ports:-}" ]]; then
    record_summary "check" "effective port assert" "-" "-" "FAILED (no sshd -T port output)"
    echo "ERROR: Cannot determine effective sshd port via sshd -T; rolling back."
    restore_backups
    echo
    print_summary
    exit 4
  fi

  if [[ "$ports" != "$FIXED_PORT" ]]; then
    record_summary "check" "effective port assert" "$ports" "$FIXED_PORT" "FAILED (effective ports != ${FIXED_PORT})"
    echo "ERROR: Effective sshd ports are '$ports' (expected only '$FIXED_PORT'). Rolling back."
    restore_backups
    echo
    print_summary
    exit 4
  fi

  record_summary "check" "effective port assert" "$ports" "$FIXED_PORT" "passed"
}

reload_sshd_if_requested() {
  if [[ "$DO_RELOAD" != true ]]; then
    record_summary "check" "systemctl reload sshd" "-" "-" "skipped (--no-reload)"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    record_summary "check" "systemctl reload sshd" "-" "-" "skipped (no systemctl)"
    return 0
  fi

  # 兼容有些系统服务名是 ssh 而不是 sshd
  local svc="sshd"
  if ! systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
      svc="ssh"
    fi
  fi

  if systemctl reload "$svc" 2>/dev/null; then
    record_summary "check" "systemctl reload $svc" "-" "-" "ok"
    return 0
  fi

  # reload 失败则尝试 restart
  if systemctl restart "$svc" 2>/dev/null; then
    record_summary "check" "systemctl reload $svc" "-" "-" "reload failed; restart ok"
    return 0
  fi

  record_summary "check" "systemctl reload $svc" "-" "-" "FAILED (reload+restart)"
  echo "ERROR: systemctl reload/restart $svc failed."
  echo
  print_summary
  exit 5
}

main() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: please run as root."
    exit 1
  fi

  echo "Target fixed SSH port: ${FIXED_PORT}"
  echo "Dry run: ${DRY_RUN}"
  echo "Auto reload: ${DO_RELOAD}"
  echo "Process sshd_config.d: ${DO_PROCESS_D}"
  echo "Only process sshd_config.d: ${ONLY_D}"
  echo

  # pre checks
  record_sshd_effective_ports "pre"
  check_port_available_or_exit "$FIXED_PORT"

  # modify
  if [[ "$ONLY_D" != true ]]; then
    replace_or_append_port_in_file "$SERVER_MAIN"
  else
    record_summary "skip" "$SERVER_MAIN" "-" "-" "skipped (--only-sshd-config-d)"
  fi

  if [[ "$DO_PROCESS_D" == true ]]; then
    shopt -s nullglob
    local d_files=($SERVER_D_GLOB)
    shopt -u nullglob

    if (( ${#d_files[@]} == 0 )); then
      record_summary "skip" "/etc/ssh/sshd_config.d/*.conf" "-" "-" "no files"
    else
      local f
      for f in "${d_files[@]}"; do
        replace_or_append_port_in_file "$f"
      done
    fi
  else
    record_summary "skip" "/etc/ssh/sshd_config.d/*.conf" "-" "-" "skipped (processing disabled)"
  fi

  echo

  if [[ "$DRY_RUN" == true ]]; then
    record_summary "check" "sshd -t" "-" "-" "skipped (dry-run)"
    record_summary "check" "effective port assert" "-" "-" "skipped (dry-run)"
    record_summary "check" "systemctl reload sshd" "-" "-" "skipped (dry-run)"
    print_summary
    exit 0
  fi

  # validate -> rollback on failure
  if command -v sshd >/dev/null 2>&1; then
    echo "==> validating sshd config (sshd -t) ..."
    if sshd -t; then
      echo "  OK: sshd config test passed."
      record_summary "check" "sshd -t" "-" "-" "passed"
    else
      echo "  ERROR: sshd config test FAILED. Rolling back..."
      record_summary "check" "sshd -t" "-" "-" "FAILED -> rollback"
      restore_backups
      record_sshd_effective_ports "post"
      print_summary
      exit 2
    fi
  else
    record_summary "check" "sshd -t" "-" "-" "skipped (sshd not found)"
  fi

  # assert effective port -> rollback if mismatch
  assert_effective_port_or_rollback

  # reload if requested
  reload_sshd_if_requested

  # record post
  record_sshd_effective_ports "post"

  echo
  print_summary

  echo
  echo "Next steps:"
  echo "  - Ensure firewall/SG allows TCP ${FIXED_PORT}"
  echo "  - Keep current SSH session until new port verified"
}

main "$@"