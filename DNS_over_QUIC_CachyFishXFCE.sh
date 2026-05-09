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

get_wifi_connection() {
  nmcli -t -f NAME,TYPE con show --active 2>/dev/null \
    | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

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

set_resolv_loopback() {
  unlock_resolv
  if [[ -e "$RESOLV_CONF" && ! -e "$RESOLV_BACKUP" ]]; then
    cp -aL "$RESOLV_CONF" "$RESOLV_BACKUP" 2>/dev/null || true
  fi
  rm -f "$RESOLV_CONF"
  printf 'nameserver 127.0.0.1\nnameserver ::1\n' > "$RESOLV_CONF"
  lock_resolv
  ok "Set /etc/resolv.conf -> 127.0.0.1 (locked immutable)"
}

restore_resolv() {
  unlock_resolv
  rm -f "$RESOLV_CONF"
  if [[ -e "$RESOLV_BACKUP" ]]; then
    cp -a "$RESOLV_BACKUP" "$RESOLV_CONF"
    rm -f "$RESOLV_BACKUP"
    ok "Restored previous /etc/resolv.conf from backup"
  else
    ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF" 2>/dev/null \
      || printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$RESOLV_CONF"
    ok "Created default /etc/resolv.conf"
  fi
  unlock_resolv
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

set_nm_dns() {
  local conn="$1" v4="$2" v6="$3"
  if [[ -z "$conn" ]]; then
    warn "No active WiFi connection — skipping NetworkManager DNS update."
    return
  fi
  if [[ -n "$v4" ]]; then
    nmcli con mod "$conn" ipv4.ignore-auto-dns yes ipv4.dns "$v4"
  else
    nmcli con mod "$conn" ipv4.ignore-auto-dns no  ipv4.dns ""
  fi
  if [[ -n "$v6" ]]; then
    nmcli con mod "$conn" ipv6.ignore-auto-dns yes ipv6.dns "$v6"
  else
    nmcli con mod "$conn" ipv6.ignore-auto-dns no  ipv6.dns ""
  fi
  nmcli con down "$conn" >/dev/null 2>&1 || true
  nmcli con up   "$conn" >/dev/null 2>&1 || true
  ok "NetworkManager DNS updated for: $conn"
}

# ---------- Actions ----------
do_enable() {
  require_root "$@"
  ensure_tools
  info "Enabling DNS-over-QUIC..."

  ensure_dnsproxy_installed

  if systemctl is-active --quiet systemd-resolved; then
    info "Disabling systemd-resolved (frees port 53)"
    systemctl disable --now systemd-resolved
  fi

  write_dnsproxy_config
  configure_ufw
  set_resolv_loopback

  systemctl enable dnsproxy  >/dev/null 2>&1 || true
  systemctl restart dnsproxy
  sleep 2

  if ! systemctl is-active --quiet dnsproxy; then
    err "dnsproxy failed to start. Inspect: journalctl -u dnsproxy -n 40 --no-pager"
    exit 1
  fi
  ok "dnsproxy is running"

  local wifi
  wifi="$(get_wifi_connection)"
  set_nm_dns "$wifi" "127.0.0.1" "::1"

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
  info "Disabling DNS-over-QUIC..."

  # Reset Mullvad first so it stops pointing at a soon-to-be-dead 127.0.0.1.
  mullvad_use_default_dns

  if systemctl is-active --quiet dnsproxy; then
    systemctl stop dnsproxy
  fi
  systemctl disable dnsproxy >/dev/null 2>&1 || true
  ok "Stopped + disabled dnsproxy"

  restore_resolv

  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
    systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    ok "Re-enabled systemd-resolved"
  fi

  local wifi
  wifi="$(get_wifi_connection)"
  set_nm_dns "$wifi" "" ""

  ok "DoQ DISABLED — DNS reverted to DHCP / VPN-managed."
  if mullvad_present; then
    info "Mullvad now uses its default (Mullvad-operated) DNS."
  fi
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

  local wifi
  wifi="$(get_wifi_connection)"
  if [[ -n "$wifi" ]]; then
    echo "Active WiFi DNS ($wifi):"
    nmcli -g ipv4.dns,ipv6.dns con show "$wifi" 2>/dev/null | sed 's/^/  /'
  fi

  if mullvad_present; then
    echo "Mullvad state:"
    mullvad status 2>/dev/null | sed 's/^/  /' || true
    echo "Mullvad DNS settings:"
    mullvad dns get 2>/dev/null | sed 's/^/  /' || true
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
  --disable) do_disable "$@" ;;
  --status)  do_status ;;
  -h|--help|"")
    cat <<EOF
DNS-over-QUIC manager for CachyOS + XFCE (with Mullvad VPN sync)

Usage:
  sudo $0 --enable     Configure dnsproxy with DoQ upstreams, redirect system DNS to 127.0.0.1.
                       Also sets Mullvad to: custom DNS = 127.0.0.1, LAN allow.
  sudo $0 --disable    Stop dnsproxy, restore systemd-resolved + DHCP DNS.
                       Also resets Mullvad to its default DNS.
       $0 --status     Show current DoQ + Mullvad state.

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
