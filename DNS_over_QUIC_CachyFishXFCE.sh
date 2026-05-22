#!/usr/bin/env bash
# DNS_over_QUIC_CachyFishXFCE.sh
# Toggle system-wide DNS-over-QUIC on CachyOS (XFCE) using AdGuard dnsproxy.
#
# Usage:
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --enable
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --disable
#   sudo ./DNS_over_QUIC_CachyFishXFCE.sh --status

set -euo pipefail

# ---------- Configuration ----------
DNSPROXY_CONFIG="/etc/dnsproxy/dnsproxy.yaml"
RESOLV_CONF="/etc/resolv.conf"

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
  for c in dig nmcli systemctl awk sed chattr; do
    command -v "$c" >/dev/null 2>&1 || { err "Missing required command: $c"; exit 1; }
  done
}

write_dnsproxy_config() {
  mkdir -p "$(dirname "$DNSPROXY_CONFIG")"
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
max-go-routines: 0
EOF
  } > "$DNSPROXY_CONFIG"
  ok "Wrote dnsproxy config: $DNSPROXY_CONFIG"
}

configure_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  if ufw status verbose 2>/dev/null | grep -qiE "deny.*\(outgoing\)"; then
    info "UFW denies outgoing — adding rules for DNS/DoQ"
    ufw allow out 53/udp  >/dev/null
    ufw allow out 53/tcp  >/dev/null
    ufw allow out 853/udp >/dev/null
    ufw reload >/dev/null
    ok "UFW outbound rules added"
  fi
}

# ---------- Actions ----------
do_enable() {
  require_root "$@"
  ensure_tools
  info "Enabling DNS-over-QUIC..."

  ensure_dnsproxy_installed

  # 1. Stop systemd-resolved to free port 53
  if systemctl is-active --quiet systemd-resolved; then
    info "Disabling systemd-resolved (frees port 53)"
    systemctl disable --now systemd-resolved 2>/dev/null || true
  fi

  write_dnsproxy_config
  configure_ufw

  # 2. Start dnsproxy
  systemctl enable dnsproxy >/dev/null 2>&1 || true
  systemctl restart dnsproxy
  sleep 2

  if ! systemctl is-active --quiet dnsproxy; then
    err "dnsproxy failed to start. Inspect: journalctl -u dnsproxy -n 40 --no-pager"
    exit 1
  fi
  ok "dnsproxy is running"

  # 3. Configure ALL NetworkManager profiles to use local DNS
  info "Routing NetworkManager profiles to 127.0.0.1..."
  for uuid in $(nmcli -t -f UUID con show 2>/dev/null); do
    [[ -z "$uuid" ]] && continue
    nmcli con mod "$uuid" ipv4.ignore-auto-dns yes ipv4.dns "127.0.0.1" 2>/dev/null || true
    nmcli con mod "$uuid" ipv6.ignore-auto-dns yes ipv6.dns "::1" 2>/dev/null || true
  done

  # 4. Set resolv.conf explicitly
  # (Unlocks the file first in case an older script left it immutable)
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
  rm -f "$RESOLV_CONF"
  printf 'nameserver 127.0.0.1\nnameserver ::1\n' > "$RESOLV_CONF"
  
  # Restart NM to apply cleanly
  systemctl restart NetworkManager
  sleep 2

  # 5. Verification
  info "Test query via 127.0.0.1..."
  if dig @127.0.0.1 example.com +short +timeout=3 +tries=1 | grep -qE '^[0-9a-f.:]+$'; then
    ok "DoQ active and resolving."
  else
    warn "Test query failed. Check: journalctl -u dnsproxy -f"
  fi

  echo
  ok "DoQ ENABLED!"
  warn "If using Mullvad VPN, you MUST set Custom DNS to 127.0.0.1 in the Mullvad app."
}

do_disable() {
  require_root "$@"
  ensure_tools
  info "Disabling DNS-over-QUIC and restoring default DHCP/systemd-resolved..."

  # 1. Stop dnsproxy
  systemctl disable --now dnsproxy >/dev/null 2>&1 || true
  ok "Stopped and disabled dnsproxy"

  # 2. Revert ALL NetworkManager profiles to automatic (DHCP) DNS
  info "Reverting NetworkManager profiles to Auto (DHCP)..."
  for uuid in $(nmcli -t -f UUID con show 2>/dev/null); do
    [[ -z "$uuid" ]] && continue
    nmcli con mod "$uuid" ipv4.ignore-auto-dns no ipv4.dns "" 2>/dev/null || true
    nmcli con mod "$uuid" ipv6.ignore-auto-dns no ipv6.dns "" 2>/dev/null || true
  done

  # 3. Restore systemd-resolved (CachyOS default)
  info "Restoring systemd-resolved..."
  systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
  
  # 4. Rebuild resolv.conf symlink
  # (Unlocks the file first in case an older script left it immutable)
  chattr -i "$RESOLV_CONF" 2>/dev/null || true
  rm -f "$RESOLV_CONF"
  ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF" 2>/dev/null || true
  ok "Restored /etc/resolv.conf systemd-resolved symlink"

  # Restart NetworkManager so it negotiates DHCP properly
  systemctl restart NetworkManager
  sleep 3

  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null || true
  fi

  # 5. Verification
  echo
  info "Testing standard DNS resolution..."
  if dig example.com +short +timeout=3 +tries=1 2>/dev/null | grep -m1 -oE '^[0-9a-f.:]+$' >/dev/null; then
    ok "System default resolver works. Plain Internet is fully restored."
  else
    warn "System default resolver test failed. Try reconnecting your Wi-Fi."
  fi

  echo
  ok "DoQ DISABLED — system returned to default DHCP."
  warn "If using Mullvad VPN, switch DNS back to 'Default' in the Mullvad app."
}

do_status() {
  echo "${BLU}=== DNS-over-QUIC Status ===${NC}"

  printf "%-24s " "dnsproxy service:"
  if systemctl is-active --quiet dnsproxy; then echo "${GRN}active${NC}"; else echo "${RED}inactive${NC}"; fi

  printf "%-24s " "systemd-resolved:"
  if systemctl is-active --quiet systemd-resolved; then echo "${GRN}active${NC}"; else echo "${RED}inactive${NC}"; fi

  echo -e "\n${BLU}--- /etc/resolv.conf ---${NC}"
  if [[ -L "$RESOLV_CONF" ]]; then
    echo "Symlinked to: $(readlink "$RESOLV_CONF")"
  fi
  sed 's/^/  /' "$RESOLV_CONF" 2>/dev/null || echo "  (missing)"

  echo -e "\n${BLU}--- Active NM Connections ---${NC}"
  for uuid in $(nmcli -t -f UUID con show --active 2>/dev/null); do
    [[ -z "$uuid" ]] && continue
    name=$(nmcli -g GENERAL.NAME con show "$uuid" 2>/dev/null)
    v4=$(nmcli -g ipv4.dns con show "$uuid" 2>/dev/null)
    echo "  Profile: $name | IPv4 DNS: ${v4:-Auto(DHCP)}"
  done

  if command -v dig >/dev/null; then
    echo -e "\n${BLU}--- Test Query (@127.0.0.1) ---${NC}"
    dig @127.0.0.1 example.com +short +timeout=2 +tries=1 2>/dev/null | sed 's/^/  /' || echo "  (no response)"
  fi
}

# ---------- Main ----------
case "${1:-}" in
  --enable)  do_enable  "$@" ;;
  --disable|--revert) do_disable "$@" ;;
  --status)  do_status ;;
  -h|--help|"")
    cat <<EOF
DNS-over-QUIC manager for CachyOS + XFCE

Usage:
  sudo $0 --enable    Configures system to route DNS to local dnsproxy.
  sudo $0 --disable   Restores CachyOS default state (systemd-resolved + DHCP).
  sudo $0 --status    Show current DoQ configuration state.

Mullvad VPN Instructions:
  - When DoQ is ENABLED: Set Mullvad DNS to "Custom" -> 127.0.0.1
  - When DoQ is DISABLED: Set Mullvad DNS back to "Default"
EOF
    [[ -z "${1:-}" ]] && exit 1 || exit 0
    ;;
  *)
    err "Unknown option: $1"
    echo "Run '$0 --help' for usage."
    exit 1
    ;;
esac
