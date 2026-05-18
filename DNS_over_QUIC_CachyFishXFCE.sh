#!/usr/bin/env bash
# DNS_over_QUIC_CachyFishXFCE.sh
# Toggle system-wide DNS-over-QUIC on CachyOS (XFCE) using AdGuard dnsproxy.
# Also syncs Mullvad VPN's DNS setting so toggling works cleanly with VPN use.
#
# Usage:
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --enable
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --disable
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --status

set -euo pipefail

# ---------- Configuration ----------
DNSPROXY_CONFIG="/etc/dnsproxy/dnsproxy.yaml"
DNSPROXY_BACKUP="/etc/dnsproxy/dnsproxy.yaml.predoq.bak"
RESOLV_CONF="/etc/resolv.conf"
RESOLV_BACKUP="/etc/resolv.conf.predoq.bak"
STATE_FILE="/etc/dnsproxy/.doq_state"
NM_CONF="/etc/NetworkManager/NetworkManager.conf"
NM_CONF_BACKUP="/etc/NetworkManager/NetworkManager.conf.predoq.bak"

# Public DNS to use when disabled
PUBLIC_DNS_V4="1.1.1.1,9.9.9.9"
PUBLIC_DNS_V6="2606:4700:4700::1111,2620:fe::fe"

# Edit this list to change upstreams. Use quic://hostname for DoQ.
UPSTREAMS=(
  "quic://dns.quad9.net"
  "quic://unfiltered.adguard-dns.com"
)

# ---------- Colors ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; NC=""
fi
info() { echo "${BLU}[*]${NC} $*"; }
ok()   { echo "${GRN}[+]${NC} $*"; }
warn() { echo "${YLW}[!]${NC} $*"; }
err()  { echo "${RED}[x]${NC} $*" >&2; }

# ---------- Helpers ----------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Must run as root. Try: sudo $0 $*"
    exit 1
  fi
}

unlock_resolv() { chattr -i "$RESOLV_CONF" 2>/dev/null || true; }
lock_resolv()   { chattr +i "$RESOLV_CONF" 2>/dev/null || true; }

mullvad_present() { command -v mullvad >/dev/null 2>&1; }

mullvad_is_connected() {
  mullvad_present || return 1
  mullvad status 2>/dev/null | grep -qiE 'connected'
}

mullvad_use_local_dns() {
  mullvad_present || return 0
  info "Configuring Mullvad: custom DNS 127.0.0.1, LAN allow"
  mullvad dns set custom 127.0.0.1 >/dev/null 2>&1 || warn "mullvad dns set custom failed"
  mullvad lan set allow            >/dev/null 2>&1 || true
  if mullvad_is_connected; then
    info "Reconnecting Mullvad to apply DNS change"
    mullvad reconnect >/dev/null 2>&1 || true
  fi
}

mullvad_use_default_dns() {
  mullvad_present || return 0
  info "Resetting Mullvad to default DNS"
  mullvad dns set default >/dev/null 2>&1 || warn "mullvad dns set default failed"
  if mullvad_is_connected; then
    info "Reconnecting Mullvad to apply DNS change"
    mullvad reconnect >/dev/null 2>&1 || true
  fi
}

mullvad_kill_switch_warn() {
  mullvad_present || return 0
  if mullvad lockdown-mode get 2>/dev/null | grep -qiE 'on|enabled'; then
    echo
    warn "╔══════════════════════════════════════════════════════════════╗"
    warn "║  Mullvad kill-switch (lockdown mode) is ENABLED.             ║"
    warn "║  ALL traffic is blocked when Mullvad is DISCONNECTED.          ║"
    warn "║  If you want Internet without the VPN, run:                   ║"
    warn "║      mullvad lockdown-mode set off                             ║"
    warn "╚══════════════════════════════════════════════════════════════╝"
    echo
  fi
}

ensure_dnsproxy_installed() {
  if command -v dnsproxy >/dev/null 2>&1; then
    return
  fi
  info "Installing dnsproxy from AUR..."
  local helper=""
  if command -v paru >/dev/null 2>&1; then helper="paru"
  elif command -v yay >/dev/null 2>&1; then helper="yay"
  else
    err "Neither paru nor yay found. Install an AUR helper first."
    exit 1
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" "$helper" -S --noconfirm dnsproxy
  else
    err "Run with 'sudo' from a normal user account so $helper can build the AUR package."
    exit 1
  fi
}

ensure_tools() {
  for c in dig nmcli systemctl chattr awk sed; do
    command -v "$c" >/dev/null 2>&1 || { err "Missing required command: $c"; exit 1; }
  done
}

write_dnsproxy_config() {
  mkdir -p "$(dirname "$DNSPROXY_CONFIG")"
  if [[ -f "$DNSPROXY_CONFIG" && ! -f "$DNSPROXY_BACKUP" ]]; then
    cp -a "$DNSPROXY_CONFIG" "$DNSPROXY_BACKUP"
    info "Backed up existing config to $DNSPROXY_BACKUP"
  fi

  {
    cat <<'EOF'
---
bootstrap:
  - "9.9.9.9:53"
  - "1.1.1.1:53"
dnssec: true
listen-addrs:
  - "127.0.0.1"
  - "::1"
listen-ports:
  - 53
upstream:
EOF
    for u in "${UPSTREAMS[@]}"; do
      printf '  - "%s"\n' "$u"
    done
    cat <<'EOF'
cache: true
cache-size: 4194304
timeout: '10s'
ratelimit: 0
ratelimit-subnet-len-ipv4: 24
ratelimit-subnet-len-ipv6: 64
max-go-routines: 0
udp-buf-size: 0
EOF
  } > "$DNSPROXY_CONFIG"

  ok "Wrote dnsproxy config: $DNSPROXY_CONFIG"
}

# ---------- State tracking ----------
save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  : > "$STATE_FILE"

  # resolv.conf metadata
  if [[ -L "$RESOLV_CONF" ]]; then
    echo "RESOLV_WAS_SYMLINK=1" >> "$STATE_FILE"
    echo "RESOLV_SYMLINK_TARGET=$(readlink "$RESOLV_CONF")" >> "$STATE_FILE"
  else
    echo "RESOLV_WAS_SYMLINK=0" >> "$STATE_FILE"
  fi

  # systemd-resolved state
  systemctl is-enabled systemd-resolved &>/dev/null && echo "SYSTEMD_RESOLVED_ENABLED=1" >> "$STATE_FILE" || echo "SYSTEMD_RESOLVED_ENABLED=0" >> "$STATE_FILE"
  systemctl is-active systemd-resolved &>/dev/null && echo "SYSTEMD_RESOLVED_ACTIVE=1" >> "$STATE_FILE" || echo "SYSTEMD_RESOLVED_ACTIVE=0" >> "$STATE_FILE"

  # NetworkManager DNS backend
  if grep -qE '^dns\s*=\s*systemd-resolved' "$NM_CONF" 2>/dev/null; then
    echo "NM_DNS_BACKEND=systemd-resolved" >> "$STATE_FILE"
  else
    echo "NM_DNS_BACKEND=default" >> "$STATE_FILE"
  fi

  # NetworkManager active connections (by UUID)
  nmcli -t -f UUID,TYPE con show --active 2>/dev/null | while IFS=: read -r uuid _type; do
    [[ -z "$uuid" ]] && continue
    local v4_dns v4_ignore v6_dns v6_ignore
    v4_dns=$(nmcli -g ipv4.dns con show "$uuid" 2>/dev/null || true)
    v4_ignore=$(nmcli -g ipv4.ignore-auto-dns con show "$uuid" 2>/dev/null || true)
    v6_dns=$(nmcli -g ipv6.dns con show "$uuid" 2>/dev/null || true)
    v6_ignore=$(nmcli -g ipv6.ignore-auto-dns con show "$uuid" 2>/dev/null || true)
    {
      echo "NM_UUID_${uuid}_V4_DNS=${v4_dns}"
      echo "NM_UUID_${uuid}_V4_IGNORE=${v4_ignore}"
      echo "NM_UUID_${uuid}_V6_DNS=${v6_dns}"
      echo "NM_UUID_${uuid}_V6_IGNORE=${v6_ignore}"
    } >> "$STATE_FILE"
  done
}

load_state_var() {
  local key="$1"
  grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true
}

clear_state() {
  rm -f "$STATE_FILE"
}

# ---------- resolv.conf robust backup / restore ----------
sanitize_backup() {
  if [[ -e "$RESOLV_BACKUP" ]]; then
    if [[ ! -L "$RESOLV_BACKUP" ]] && grep -qE '^nameserver\s+127\.' "$RESOLV_BACKUP" 2>/dev/null; then
      warn "Existing backup contains loopback (corrupted by previous run). Discarding."
      rm -f "$RESOLV_BACKUP"
    fi
  fi
}

backup_resolv_robust() {
  unlock_resolv
  sanitize_backup
  if [[ -e "$RESOLV_BACKUP" ]]; then
    return
  fi

  if [[ -L "$RESOLV_CONF" ]]; then
    cp -P "$RESOLV_CONF" "$RESOLV_BACKUP"
  elif [[ -f "$RESOLV_CONF" ]]; then
    cp -a "$RESOLV_CONF" "$RESOLV_BACKUP"
  fi
}

restore_resolv_factory() {
  unlock_resolv
  rm -f "$RESOLV_CONF"

  if [[ -e "$RESOLV_BACKUP" ]]; then
    if [[ -L "$RESOLV_BACKUP" ]]; then
      cp -P "$RESOLV_BACKUP" "$RESOLV_CONF"
    else
      cp -a "$RESOLV_BACKUP" "$RESOLV_CONF"
    fi
    rm -f "$RESOLV_BACKUP"
    ok "Restored original /etc/resolv.conf from backup"
  else
    if systemctl is-enabled systemd-resolved &>/dev/null || systemctl is-active systemd-resolved &>/dev/null; then
      ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF" 2>/dev/null || true
      ok "Linked /etc/resolv.conf -> systemd-resolved stub"
    else
      printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions edns0 trust-ad\n' > "$RESOLV_CONF"
      ok "Created default /etc/resolv.conf with public DNS"
    fi
  fi
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
}

set_resolv_loopback() {
  unlock_resolv
  rm -f "$RESOLV_CONF"
  printf 'nameserver 127.0.0.1\nnameserver ::1\n' > "$RESOLV_CONF"
  lock_resolv
  ok "Set /etc/resolv.conf -> 127.0.0.1 (locked immutable)"
}

set_resolv_public() {
  unlock_resolv
  rm -f "$RESOLV_CONF"
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions edns0 trust-ad\n' > "$RESOLV_CONF"
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
  ok "Set /etc/resolv.conf to public DNS (1.1.1.1, 9.9.9.9)"
}

# ---------- NetworkManager DNS backend ----------
nm_use_systemd_resolved() {
  if [[ ! -f "$NM_CONF" ]]; then
    warn "$NM_CONF not found; skipping NM backend config."
    return
  fi
  if ! grep -qE '^dns\s*=\s*systemd-resolved' "$NM_CONF" 2>/dev/null; then
    info "Switching NetworkManager DNS backend -> systemd-resolved"
    if [[ ! -f "$NM_CONF_BACKUP" ]]; then
      cp -a "$NM_CONF" "$NM_CONF_BACKUP"
    fi
    # Ensure [main] section exists and set dns=systemd-resolved
    if grep -q '^\[main\]' "$NM_CONF"; then
      sed -i '/^\[main\]/a dns=systemd-resolved' "$NM_CONF"
    else
      echo -e "\n[main]\ndns=systemd-resolved" >> "$NM_CONF"
    fi
  fi
}

nm_use_default_dns() {
  if [[ ! -f "$NM_CONF" ]]; then
    warn "$NM_CONF not found; skipping NM backend config."
    return
  fi
  if grep -qE '^dns\s*=\s*systemd-resolved' "$NM_CONF" 2>/dev/null; then
    info "Switching NetworkManager DNS backend -> default"
    if [[ ! -f "$NM_CONF_BACKUP" ]]; then
      cp -a "$NM_CONF" "$NM_CONF_BACKUP"
    fi
    sed -i 's/^\s*dns\s*=\s*systemd-resolved\s*/dns=default/' "$NM_CONF"
  fi
}

nm_restore_backend() {
  if [[ -f "$NM_CONF_BACKUP" ]]; then
    cp -a "$NM_CONF_BACKUP" "$NM_CONF"
    rm -f "$NM_CONF_BACKUP"
    ok "Restored original NetworkManager.conf"
  fi
}

# ---------- NetworkManager: all active connections ----------
get_active_uuids() {
  nmcli -t -f UUID,TYPE con show --active 2>/dev/null | while IFS=: read -r uuid _type; do
    [[ -n "$uuid" ]] && echo "$uuid"
  done
}

set_all_nm_dns_loopback() {
  local uuid
  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue
    nmcli con mod "$uuid" ipv4.ignore-auto-dns yes ipv4.dns "127.0.0.1" 2>/dev/null || warn "Failed to set IPv4 DNS for $uuid"
    nmcli con mod "$uuid" ipv6.ignore-auto-dns yes ipv6.dns "::1" 2>/dev/null || warn "Failed to set IPv6 DNS for $uuid"
    nmcli con up "$uuid" >/dev/null 2>&1 || true
  done < <(get_active_uuids)
}

set_all_nm_dns_public() {
  local uuid
  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue
    nmcli con mod "$uuid" ipv4.ignore-auto-dns yes ipv4.dns "$PUBLIC_DNS_V4" 2>/dev/null || warn "Failed to set IPv4 public DNS for $uuid"
    nmcli con mod "$uuid" ipv6.ignore-auto-dns yes ipv6.dns "$PUBLIC_DNS_V6" 2>/dev/null || true
    nmcli con up "$uuid" >/dev/null 2>&1 || true
  done < <(get_active_uuids)
}

restore_all_nm_dns() {
  local uuid v4_dns v4_ignore v6_dns v6_ignore

  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue

    if [[ -f "$STATE_FILE" ]] && grep -q "NM_UUID_${uuid}_V4_DNS" "$STATE_FILE" 2>/dev/null; then
      v4_dns=$(load_state_var "NM_UUID_${uuid}_V4_DNS")
      v4_ignore=$(load_state_var "NM_UUID_${uuid}_V4_IGNORE")
      v6_dns=$(load_state_var "NM_UUID_${uuid}_V6_DNS")
      v6_ignore=$(load_state_var "NM_UUID_${uuid}_V6_IGNORE")

      nmcli con mod "$uuid" ipv4.ignore-auto-dns "${v4_ignore:-no}" -- ipv4.dns "${v4_dns}" 2>/dev/null || true
      nmcli con mod "$uuid" ipv6.ignore-auto-dns "${v6_ignore:-no}" -- ipv6.dns "${v6_dns}" 2>/dev/null || true
    else
      nmcli con mod "$uuid" ipv4.ignore-auto-dns no -- ipv4.dns "" 2>/dev/null || true
      nmcli con mod "$uuid" ipv6.ignore-auto-dns no -- ipv6.dns "" 2>/dev/null || true
    fi
    nmcli con up "$uuid" >/dev/null 2>&1 || true
  done < <(get_active_uuids)

  # Safety sweep: nuke 127.0.0.1 from *all* connection profiles
  while IFS=: read -r uuid _type; do
    [[ -z "$uuid" ]] && continue
    local current_v4 current_v6
    current_v4=$(nmcli -g ipv4.dns con show "$uuid" 2>/dev/null || true)
    current_v6=$(nmcli -g ipv6.dns con show "$uuid" 2>/dev/null || true)
    if [[ "$current_v4" == *"127.0.0.1"* || "$current_v6" == *"::1"* ]]; then
      warn "Connection $uuid still has loopback DNS — clearing to auto."
      nmcli con mod "$uuid" ipv4.ignore-auto-dns no -- ipv4.dns "" 2>/dev/null || true
      nmcli con mod "$uuid" ipv6.ignore-auto-dns no -- ipv6.dns "" 2>/dev/null || true
    fi
  done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)
}

sweep_nm_loopback() {
  local uuid current_v4 current_v6
  while IFS=: read -r uuid _type; do
    [[ -z "$uuid" ]] && continue
    current_v4=$(nmcli -g ipv4.dns con show "$uuid" 2>/dev/null || true)
    current_v6=$(nmcli -g ipv6.dns con show "$uuid" 2>/dev/null || true)
    if [[ "$current_v4" == *"127.0.0.1"* || "$current_v6" == *"::1"* ]]; then
      warn "Connection $uuid still has loopback DNS — forcing public DNS."
      nmcli con mod "$uuid" ipv4.ignore-auto-dns yes ipv4.dns "$PUBLIC_DNS_V4" 2>/dev/null || true
      nmcli con mod "$uuid" ipv6.ignore-auto-dns yes ipv6.dns "$PUBLIC_DNS_V6" 2>/dev/null || true
    fi
  done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)
}

configure_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  if ufw status verbose 2>/dev/null | grep -qiE "deny.*\(outgoing\)"; then
    info "UFW denies outgoing — adding rules for DNS/DoQ/DoH3"
    ufw allow out 53/udp  >/dev/null
    ufw allow out 53/tcp  >/dev/null
    ufw allow out 853/udp >/dev/null
    ufw allow out 853/tcp >/dev/null
    ufw allow out 443/udp >/dev/null
    ufw reload >/dev/null
    ok "UFW outbound rules added"
  fi
}

# ---------- Actions ----------
do_enable() {
  require_root "$@"
  ensure_tools
  info "Enabling DNS-over-QUIC..."

  save_state
  ensure_dnsproxy_installed

  if systemctl is-active --quiet systemd-resolved; then
    info "Disabling systemd-resolved (frees port 53)"
    systemctl disable --now systemd-resolved
  fi

  nm_use_systemd_resolved
  write_dnsproxy_config
  configure_ufw
  backup_resolv_robust
  set_resolv_loopback

  systemctl enable dnsproxy  >/dev/null 2>&1 || true
  systemctl restart dnsproxy
  sleep 2

  if ! systemctl is-active --quiet dnsproxy; then
    err "dnsproxy failed to start. Inspect: journalctl -u dnsproxy -n 40 --no-pager"
    exit 1
  fi
  ok "dnsproxy is running"

  set_all_nm_dns_loopback
  mullvad_use_local_dns

  sleep 1
  info "Test query via 127.0.0.1..."
  if dig @127.0.0.1 example.com +short +timeout=3 +tries=1 | grep -qE '^[0-9a-f.:]+$'; then
    ok "DoQ active and resolving."
  else
    warn "Test query failed. Check: journalctl -u dnsproxy -f"
  fi

  echo
  ok "DoQ ENABLED — upstreams in use:"
  for u in "${UPSTREAMS[@]}"; do echo "    $u"; done
  echo
  info "Verify live traffic with:  sudo tcpdump -ni any 'udp port 853'"
}

do_disable() {
  require_root "$@"
  ensure_tools
  info "Disabling DNS-over-QUIC and switching to public DNS..."

  mullvad_use_default_dns

  if systemctl is-active --quiet dnsproxy; then
    systemctl stop dnsproxy
  fi
  systemctl disable dnsproxy >/dev/null 2>&1 || true
  ok "Stopped and disabled dnsproxy"

  # Stop systemd-resolved to avoid 127.0.0.53 interference
  if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
  fi
  systemctl disable systemd-resolved >/dev/null 2>&1 || true
  ok "Stopped and disabled systemd-resolved"

  # Switch NM away from systemd-resolved so it writes real IPs to resolv.conf
  nm_use_default_dns

  # Force all NetworkManager connections to public DNS
  set_all_nm_dns_public
  sweep_nm_loopback

  # Restart NetworkManager so it picks up the backend change
  info "Restarting NetworkManager..."
  systemctl restart NetworkManager
  sleep 3

  # NetworkManager may have regenerated resolv.conf. If it still points to 127.0.0.53,
  # force a real public-DNS file and make it immutable so NM cannot overwrite it.
  if grep -qE '^nameserver\s+127\.0\.0\.53' "$RESOLV_CONF" 2>/dev/null; then
    warn "NetworkManager still wrote 127.0.0.53 to resolv.conf — forcing public DNS file."
    unlock_resolv
    rm -f "$RESOLV_CONF"
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions edns0 trust-ad\n' > "$RESOLV_CONF"
    chattr +i "$RESOLV_CONF" 2>/dev/null || true
    ok "Forced /etc/resolv.conf to public DNS and locked it."
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
  fi

  clear_state

  # Verification
  echo
  info "Testing DNS resolution..."
  sleep 2

  local direct_sys default_sys
  direct_sys=$(dig @1.1.1.1 example.com +short +timeout=3 +tries=1 2>/dev/null | grep -m1 -oE '^[0-9a-f.:]+$' || true)
  default_sys=$(dig example.com +short +timeout=3 +tries=1 2>/dev/null | grep -m1 -oE '^[0-9a-f.:]+$' || true)

  if [[ -n "$direct_sys" ]]; then
    ok "Direct DNS query to 1.1.1.1 works."
  else
    warn "Direct DNS query to 1.1.1.1 failed — check your internet link."
  fi

  if [[ -n "$default_sys" ]]; then
    ok "System default resolver works. Plain Internet (non-VPN) should be accessible."
  else
    warn "System default resolver test failed."
    warn "Current /etc/resolv.conf:"
    sed 's/^/  /' "$RESOLV_CONF" >&2 || true
    warn "Current NM DNS settings:"
    nmcli dev show 2>/dev/null | grep -i dns | sed 's/^/  /' >&2 || true
  fi

  echo
  ok "DoQ DISABLED — using public DNS ($PUBLIC_DNS_V4)."

  mullvad_kill_switch_warn
  if mullvad_present; then
    info "Mullvad now uses its default (Mullvad-operated) DNS when connected."
  fi
}

do_restore_factory() {
  require_root "$@"
  ensure_tools
  info "Restoring factory / pre-DoQ state from saved snapshot..."

  mullvad_use_default_dns

  if systemctl is-active --quiet dnsproxy; then
    systemctl stop dnsproxy
  fi
  systemctl disable dnsproxy >/dev/null 2>&1 || true
  ok "Stopped and disabled dnsproxy"

  nm_restore_backend

  restore_resolv_factory

  local was_enabled=""
  was_enabled=$(load_state_var "SYSTEMD_RESOLVED_ENABLED")
  if [[ "$was_enabled" == "1" ]]; then
    systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    ok "Re-enabled systemd-resolved"
    sleep 1
  fi

  restore_all_nm_dns

  systemctl restart NetworkManager
  sleep 2

  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
  fi

  clear_state
  ok "Factory state restored."
}

do_status() {
  echo "${BLU}=== DNS-over-QUIC Status ===${NC}"

  printf "%-24s " "dnsproxy service:"
  if systemctl is-active --quiet dnsproxy; then echo "${GRN}active${NC}"; else echo "${RED}inactive${NC}"; fi

  printf "%-24s " "dnsproxy enabled:"
  systemctl is-enabled dnsproxy 2>/dev/null || echo "no"

  printf "%-24s " "systemd-resolved:"
  systemctl is-active systemd-resolved 2>/dev/null || true

  printf "%-24s " "resolv.conf immutable:"
  if lsattr "$RESOLV_CONF" 2>/dev/null | awk '{print $1}' | grep -q i; then echo "yes"; else echo "no"; fi

  echo "/etc/resolv.conf:"
  sed 's/^/  /' "$RESOLV_CONF" 2>/dev/null || echo "  (missing)"

  if [[ -f "$DNSPROXY_CONFIG" ]]; then
    echo "Configured upstreams:"
    awk '/^upstream:/{flag=1;next} /^[a-zA-Z]/{flag=0} flag' "$DNSPROXY_CONFIG" | sed 's/^/  /'
  fi

  local uuid
  echo "Active connections (NetworkManager):"
  while IFS=: read -r uuid type; do
    [[ -z "$uuid" ]] && continue
    local name v4 v6
    name=$(nmcli -g GENERAL.NAME con show "$uuid" 2>/dev/null || echo "$uuid")
    v4=$(nmcli -g ipv4.dns con show "$uuid" 2>/dev/null || true)
    v6=$(nmcli -g ipv6.dns con show "$uuid" 2>/dev/null || true)
    echo "  $name  IPv4=$v4  IPv6=$v6"
  done < <(nmcli -t -f UUID,TYPE con show --active 2>/dev/null || true)

  if mullvad_present; then
    echo "Mullvad state:"
    mullvad status 2>/dev/null | sed 's/^/  /' || true
    echo "Mullvad DNS settings:"
    mullvad dns get 2>/dev/null | sed 's/^/  /' || true
    echo "Mullvad lockdown-mode:"
    mullvad lockdown-mode get 2>/dev/null | sed 's/^/  /' || true
  fi

  if command -v dig >/dev/null; then
    echo "Test query (example.com @127.0.0.1):"
    dig @127.0.0.1 example.com +short +timeout=2 +tries=1 2>/dev/null | sed 's/^/  /' \
      || echo "  (no response)"
  fi
}

# ---------- Main ----------
case "${1:-}" in
  --enable)  do_enable  "$@" ;;
  --disable|--revert) do_disable "$@" ;;
  --restore-factory) do_restore_factory ;;
  --status)  do_status ;;
  -h|--help|"")
    cat <<EOF
DNS-over-QUIC manager for CachyOS + XFCE (with Mullvad VPN sync)

Usage:
  sudo $0 --enable          Configure dnsproxy with DoQ upstreams, redirect system DNS to 127.0.0.1.
                            Also sets Mullvad to: custom DNS = 127.0.0.1, LAN allow.
  sudo $0 --disable         Stop dnsproxy, disable systemd-resolved, force public DNS (1.1.1.1, 9.9.9.9)
                            via NetworkManager and /etc/resolv.conf. Also resets Mullvad to default DNS.
  sudo $0 --revert          Alias for --disable.
  sudo $0 --restore-factory Try to restore exact pre-DoQ state from snapshot (resolv.conf backup, NM settings).
  sudo $0 --status          Show current DoQ + Mullvad state.

Workflow with Mullvad:
  - DoQ + VPN:           sudo $0 --enable    (then connect Mullvad)
  - Plain VPN, no DoQ:   sudo $0 --disable   (then connect Mullvad)
  - VPN already on?      Script reconnects Mullvad to apply DNS change.

Upstreams (edit UPSTREAMS array in this script to change):
$(for u in "${UPSTREAMS[@]}"; do echo "  $u"; done)
EOF
    [[ -z "${1:-}" ]] && exit 1 || exit 0
    ;;
  *)
    err "Unknown option: $1"
    echo "Run '$0 --help' for usage."
    exit 1
    ;;
esac
