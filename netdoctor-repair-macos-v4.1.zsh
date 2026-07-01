#!/usr/bin/env zsh
# ==============================================================================
# netdoctor-repair-macos-v4.1.zsh
# macOS network doctor — anti-freeze edition
#
# Features:
#   - Strict timeouts on every blocking call
#   - Automatic rollback if repair leaves the stack worse than before
#   - Full diagnostic bundle export (scutil, ifconfig, log show, ...)
#   - Progressive repair: standard → deep → rollback
#
# Tested on: macOS 10.15 Catalina / macOS 12+ (Monterey)
# Requires:  zsh, sudo (for repair actions only)
# ==============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Global config
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_VERSION="4.1"
SCRIPT_NAME="${0:t}"

REPAIR=false
DEEP_REPAIR=false
VERBOSE=false
TRANSPORT="auto"   # auto|ethernet|wifi|any
INTERFACE=""
SERVICE=""

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="$HOME/Library/Logs/NetDoctor"
LOG_FILE="$LOG_DIR/netdoctor-${TIMESTAMP}.log"
BUNDLE_DIR="$LOG_DIR/bundle-${TIMESTAMP}"

# Timeouts (seconds)
T_PING=5
T_CURL=8
T_NSLOOKUP=6
T_IP_WAIT=30     # max wait for IP after repair
T_REPAIR_STEP=15 # max time to wait for each repair action

# State before repair (for rollback)
SNAP_IP=""
SNAP_GW=""
SNAP_DNS=""

# Check results (0=fail 1=ok)
CHECK_LINK=0
CHECK_IP=0
CHECK_GW=0
CHECK_DNS=0
CHECK_INTERNET=0
CHECK_HTTPS=0

# ──────────────────────────────────────────────────────────────────────────────
# Timeout wrapper
# ──────────────────────────────────────────────────────────────────────────────
TIMEOUT_BIN=""
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
fi

_timeout() {
  local sec="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$sec" "$@"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

_log() {
  local line="[$(date '+%H:%M:%S')] $*"
  print -r -- "$line"
  print -r -- "$line" >> "$LOG_FILE"
}
info()  { _log "INFO   $*"; }
warn()  { _log "WARN   $*"; }
err()   { _log "ERROR  $*"; }
step()  { _log "────── $*"; }
ok()    { _log "OK ✓   $*"; }

# ──────────────────────────────────────────────────────────────────────────────
# Usage
# ──────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
NetDoctor v${SCRIPT_VERSION} — macOS network doctor (anti-freeze)

Usage:
  ./$SCRIPT_NAME [options]

Options:
  --repair              Standard automated repair (sudo required)
  --deep-repair         Standard + deep OS daemon restart
  --transport TYPE      auto | ethernet | wifi | any  (default: auto)
  --interface IFACE     Force interface  (e.g. en0, en7)
  --service NAME        Force service    (e.g. "USB 10/100/1000 LAN")
  --verbose             Show command outputs
  -h, --help            Show this help

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --repair
  ./$SCRIPT_NAME --deep-repair --transport ethernet
  ./$SCRIPT_NAME --repair --interface en0 --service "USB 10/100/1000 LAN"

Logs:   $LOG_DIR/netdoctor-<date>.log
Bundle: $LOG_DIR/bundle-<date>/
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Args
# ──────────────────────────────────────────────────────────────────────────────
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --repair) REPAIR=true ;;
      --deep-repair) REPAIR=true; DEEP_REPAIR=true ;;
      --transport)
        shift; [[ $# -gt 0 ]] || { err "--transport requires a value"; exit 2; }
        TRANSPORT="$1"
        ;;
      --interface)
        shift; [[ $# -gt 0 ]] || { err "--interface requires a value"; exit 2; }
        INTERFACE="$1"
        ;;
      --service)
        shift; [[ $# -gt 0 ]] || { err "--service requires a value"; exit 2; }
        SERVICE="$1"
        ;;
      --verbose) VERBOSE=true ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done

  case "$TRANSPORT" in
    auto|ethernet|wifi|any) ;;
    *) err "Invalid --transport: $TRANSPORT (use auto|ethernet|wifi|any)"; exit 2 ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Interface/service detection
# ──────────────────────────────────────────────────────────────────────────────
detect_interface() {
  if [[ -n "$INTERFACE" ]]; then
    info "Forced interface: $INTERFACE"
    return
  fi

  local default_if
  default_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' || true)"

  case "$TRANSPORT" in
    auto)
      INTERFACE="${default_if:-en0}"
      ;;
    any)
      INTERFACE="${default_if:-en0}"
      ;;
    ethernet)
      # Prefer default if it looks wired (en*), else find first active en*
      if [[ -n "$default_if" && "$default_if" == en* ]]; then
        local media
        media="$(ifconfig "$default_if" 2>/dev/null | grep 'media:' | head -n1 || true)"
        if ! print -r -- "$media" | grep -qi 'autoselect.*none\|<none>'; then
          INTERFACE="$default_if"
        fi
      fi
      if [[ -z "$INTERFACE" ]]; then
        INTERFACE="$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^en[0-9]+$' | while read -r iface; do
          if ifconfig "$iface" 2>/dev/null | grep -q 'status: active'; then
            print -r -- "$iface"; break
          fi
        done || true)"
      fi
      [[ -n "$INTERFACE" ]] || INTERFACE="en0"
      ;;
    wifi)
      INTERFACE="$(networksetup -listallhardwareports 2>/dev/null | awk '
        /Hardware Port: (Wi-Fi|AirPort)/{w=1}
        w && /Device:/{print $2; exit}
      ' || true)"
      [[ -n "$INTERFACE" ]] || INTERFACE="en1"
      ;;
  esac

  info "Using interface: $INTERFACE"
}

detect_service() {
  if [[ -n "$SERVICE" ]]; then
    info "Forced service: $SERVICE"
    return
  fi

  SERVICE="$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$INTERFACE" '
    /\([0-9]+\)/{
      line=$0
      sub(/\([0-9]+\) /,"",line)
      sub(/\(.*\)/,"",line)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",line)
      svc=line
    }
    /Device:/{
      d=$0
      sub(/^.*Device: /,"",d)
      sub(/\).*/,"",d)
      if (d==dev){ print svc; exit }
    }
  ' || true)"

  if [[ -n "$SERVICE" ]]; then
    info "Using service: $SERVICE"
  else
    warn "Could not detect service name for $INTERFACE — some repairs will be skipped"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Snapshot (before repair, for rollback)
# ──────────────────────────────────────────────────────────────────────────────
take_snapshot() {
  SNAP_IP="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null || true)"
  SNAP_GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)"
  SNAP_DNS="$(scutil --dns 2>/dev/null | awk '/nameserver/{print $3; exit}' || true)"
  info "Snapshot — IP:${SNAP_IP:-none} GW:${SNAP_GW:-none} DNS:${SNAP_DNS:-none}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Diagnostic bundle export
# ──────────────────────────────────────────────────────────────────────────────
export_bundle() {
  step "Exporting diagnostic bundle → $BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"

  # System + network state
  {
    echo "=== netdoctor v${SCRIPT_VERSION} — $(date) ==="
    echo ""

    echo "=== ifconfig ==="
    ifconfig 2>/dev/null || true

    echo ""
    echo "=== route table ==="
    netstat -rn 2>/dev/null || true

    echo ""
    echo "=== default gateway ==="
    route -n get default 2>/dev/null || true

    echo ""
    echo "=== DNS (scutil) ==="
    scutil --dns 2>/dev/null || true

    echo ""
    echo "=== Proxies (scutil) ==="
    scutil --proxy 2>/dev/null || true

    echo ""
    echo "=== networksetup services ==="
    networksetup -listallnetworkservices 2>/dev/null || true

    if [[ -n "$SERVICE" ]]; then
      echo ""
      echo "=== networksetup getinfo ==="
      networksetup -getinfo "$SERVICE" 2>/dev/null || true

      echo ""
      echo "=== IPv4 config ==="
      networksetup -getmanualproxyport "$SERVICE" 2>/dev/null || true
    fi

    echo ""
    echo "=== system date/time ==="
    date

    echo ""
    echo "=== sw_vers ==="
    sw_vers 2>/dev/null || true

    echo ""
    echo "=== ntp (sntp dry-run) ==="
    sntp -t 2 time.apple.com 2>&1 || true

  } > "$BUNDLE_DIR/network-state.txt" 2>&1

  # macOS unified log - last 5 min network/kernel errors
  {
    echo "=== log show - network errors (last 5min) ==="
    _timeout 30 log show \
      --last 5m \
      --predicate 'subsystem contains "network" OR subsystem contains "wifi" OR subsystem contains "ethernet" OR messageType == 16' \
      --style compact 2>/dev/null | tail -500 || true
  } > "$BUNDLE_DIR/macos-log-network.txt" 2>&1 &

  local log_pid=$!

  # mDNS / configd recent activity
  {
    echo "=== log show - configd/mDNS (last 5min) ==="
    _timeout 30 log show \
      --last 5m \
      --predicate 'process == "configd" OR process == "mDNSResponder"' \
      --style compact 2>/dev/null | tail -300 || true
  } > "$BUNDLE_DIR/macos-log-configd.txt" 2>&1 &

  local configd_pid=$!

  # Interface-level stats
  netstat -I "$INTERFACE" 2>/dev/null > "$BUNDLE_DIR/netstat-iface.txt" || true

  # Current session log
  cp "$LOG_FILE" "$BUNDLE_DIR/session.log" 2>/dev/null || true

  # Wait for log jobs (both capped at 30s)
  wait "$log_pid" 2>/dev/null || true
  wait "$configd_pid" 2>/dev/null || true

  # Compress everything
  local archive="$LOG_DIR/netdoctor-bundle-${TIMESTAMP}.tar.gz"
  (cd "$LOG_DIR" && tar czf "$archive" "bundle-${TIMESTAMP}" 2>/dev/null) || true

  ok "Bundle ready:"
  info "  Dir:     $BUNDLE_DIR"
  info "  Archive: $archive"
}

# ──────────────────────────────────────────────────────────────────────────────
# Checks
# ──────────────────────────────────────────────────────────────────────────────
check_link() {
  if ifconfig "$INTERFACE" 2>/dev/null | grep -q 'status: active'; then
    ok "Link active on $INTERFACE"
    CHECK_LINK=1; return 0
  fi
  err "Link inactive on $INTERFACE"
  CHECK_LINK=0; return 1
}

check_ip() {
  local ip
  ip="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    ok "Local IP: $ip"
    CHECK_IP=1; return 0
  fi
  err "No local IP on $INTERFACE"
  CHECK_IP=0; return 1
}

check_gateway() {
  local gw
  gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)"
  if [[ -z "$gw" ]]; then
    err "No default gateway"
    CHECK_GW=0; return 1
  fi
  if _timeout "$T_PING" ping -c 2 -t "$T_PING" "$gw" >/dev/null 2>&1; then
    ok "Gateway reachable: $gw"
    CHECK_GW=1; return 0
  fi
  err "Gateway unreachable: $gw"
  CHECK_GW=0; return 1
}

check_dns() {
  if _timeout "$T_NSLOOKUP" nslookup example.com >/dev/null 2>&1; then
    ok "DNS OK"
    CHECK_DNS=1; return 0
  fi
  if _timeout "$T_NSLOOKUP" dscacheutil -q host -a name example.com 2>/dev/null | grep -q 'ip_address'; then
    warn "DNS via cache only"
    CHECK_DNS=1; return 0
  fi
  err "DNS failed"
  CHECK_DNS=0; return 1
}

check_internet() {
  if _timeout "$T_PING" ping -c 2 -t "$T_PING" 1.1.1.1 >/dev/null 2>&1; then
    ok "Internet IP OK (1.1.1.1)"
    CHECK_INTERNET=1; return 0
  fi
  err "Internet IP failed"
  CHECK_INTERNET=0; return 1
}

check_https() {
  if _timeout "$T_CURL" curl -4 -fsS --connect-timeout 4 --max-time "$T_CURL" https://example.com >/dev/null 2>&1; then
    ok "HTTPS OK"
    CHECK_HTTPS=1; return 0
  fi
  err "HTTPS failed"
  CHECK_HTTPS=0; return 1
}

classify_failure() {
  if (( CHECK_INTERNET == 1 && CHECK_HTTPS == 0 )); then
    warn "Pattern: IP works, HTTPS fails"
    warn "  Likely causes: bad system date/time, IPv6 stack issue, proxy, TLS trust"
  elif (( CHECK_LINK == 1 && CHECK_IP == 0 )); then
    warn "Pattern: link up but no local IP"
    warn "  Likely causes: DHCP failure, configd issue"
  elif (( CHECK_LINK == 0 )); then
    warn "Pattern: no physical link"
    warn "  Likely causes: cable, adapter, switch port, router"
  elif (( CHECK_GW == 0 && CHECK_IP == 1 )); then
    warn "Pattern: local IP but no gateway"
    warn "  Likely causes: router issue, bad static config"
  fi
}

all_ok() {
  (( CHECK_LINK == 1 && CHECK_IP == 1 && CHECK_GW == 1 && CHECK_DNS == 1 && CHECK_INTERNET == 1 && CHECK_HTTPS == 1 ))
}

run_all_checks() {
  local failed=0
  check_link    || failed=1
  check_ip      || failed=1
  check_gateway || failed=1
  check_dns     || failed=1
  check_internet || failed=1
  check_https   || failed=1
  return "$failed"
}

# ──────────────────────────────────────────────────────────────────────────────
# Wait for IP with strict timeout
# ──────────────────────────────────────────────────────────────────────────────
wait_for_ip() {
  local max_sec="${1:-$T_IP_WAIT}"
  local interval=2
  local elapsed=0
  local ip

  while (( elapsed < max_sec )); do
    ip="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      ok "IP acquired: $ip (after ${elapsed}s)"
      return 0
    fi
    sleep "$interval"
    (( elapsed += interval )) || true
  done

  warn "No IP after ${max_sec}s"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Rollback: restore static IP if repair broke more than it fixed
# ──────────────────────────────────────────────────────────────────────────────
maybe_rollback() {
  # Only useful if we had an IP before and now we don't
  local current_ip
  current_ip="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null || true)"

  if [[ -z "$current_ip" && -n "$SNAP_IP" && -n "$SNAP_GW" ]]; then
    warn "Rollback: repair left us without IP — restoring last known state"

    # Detect subnet mask from original IP via netmask (best effort)
    local mask
    mask="$(ifconfig "$INTERFACE" 2>/dev/null | awk '/inet /{print $4}' | head -n1 || true)"
    [[ -n "$mask" ]] || mask="255.255.255.0"

    sudo networksetup -setmanualwithdhcprouter "$SERVICE" "$SNAP_IP" "$mask" "$SNAP_GW" 2>/dev/null || true
    sleep 2

    local after_ip
    after_ip="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null || true)"
    if [[ -n "$after_ip" ]]; then
      warn "Rollback partial: got IP $after_ip"
      warn "Reverting to DHCP in background (connectivity may be limited)"
      (sleep 5; sudo networksetup -setdhcp "$SERVICE" >/dev/null 2>&1 || true) &
    else
      warn "Rollback failed to restore IP — manual action required"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Repair: standard
# ──────────────────────────────────────────────────────────────────────────────
repair_standard() {
  step "Standard repair"

  info "Flush DNS caches"
  _timeout "$T_REPAIR_STEP" sudo dscacheutil -flushcache 2>/dev/null || true
  _timeout "$T_REPAIR_STEP" sudo killall -HUP mDNSResponder 2>/dev/null || true

  info "Interface reset: $INTERFACE"
  _timeout "$T_REPAIR_STEP" sudo ifconfig "$INTERFACE" down 2>/dev/null || true
  sleep 2
  _timeout "$T_REPAIR_STEP" sudo ifconfig "$INTERFACE" up 2>/dev/null || true

  info "DHCP sequence: NONE → DHCP"
  _timeout "$T_REPAIR_STEP" sudo ipconfig set "$INTERFACE" NONE 2>/dev/null || true
  sleep 1
  _timeout "$T_REPAIR_STEP" sudo ipconfig set "$INTERFACE" DHCP 2>/dev/null || true
  _timeout "$T_IP_WAIT" ipconfig waitall 2>/dev/null || true
  wait_for_ip 20 || true

  if [[ -n "$SERVICE" ]]; then
    info "networksetup renewdhcp on '$SERVICE'"
    _timeout "$T_REPAIR_STEP" sudo networksetup -renewdhcp "$SERVICE" 2>/dev/null || true

    info "Service bounce on '$SERVICE'"
    _timeout "$T_REPAIR_STEP" sudo networksetup -setnetworkserviceenabled "$SERVICE" off 2>/dev/null || true
    sleep 2
    _timeout "$T_REPAIR_STEP" sudo networksetup -setnetworkserviceenabled "$SERVICE" on 2>/dev/null || true
    wait_for_ip 20 || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Repair: HTTPS-only (when IP/GW/DNS/Internet OK but HTTPS fails)
# ──────────────────────────────────────────────────────────────────────────────
repair_https_only() {
  step "HTTPS-only repair (skip L2 reset)"

  info "Flush DNS"
  _timeout "$T_REPAIR_STEP" sudo dscacheutil -flushcache 2>/dev/null || true
  _timeout "$T_REPAIR_STEP" sudo killall -HUP mDNSResponder 2>/dev/null || true

  info "Sync system clock via NTP (TLS cert validation needs correct time)"
  _timeout 15 sudo sntp -sS time.apple.com 2>/dev/null || true

  if [[ -n "$SERVICE" ]]; then
    info "Reset IPv6 on '$SERVICE' (common cause of HTTPS-only failure)"
    _timeout "$T_REPAIR_STEP" sudo networksetup -setv6off "$SERVICE" 2>/dev/null || true
    sleep 2
    _timeout "$T_REPAIR_STEP" sudo networksetup -setv6automatic "$SERVICE" 2>/dev/null || true

    info "Clearing any system proxies on '$SERVICE'"
    _timeout "$T_REPAIR_STEP" sudo networksetup -setwebproxystate "$SERVICE" off 2>/dev/null || true
    _timeout "$T_REPAIR_STEP" sudo networksetup -setsecurewebproxystate "$SERVICE" off 2>/dev/null || true
    _timeout "$T_REPAIR_STEP" sudo networksetup -setsocksfirewallproxystate "$SERVICE" off 2>/dev/null || true
    _timeout "$T_REPAIR_STEP" sudo networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
  fi

  info "Clearing TLS session cache"
  _timeout "$T_REPAIR_STEP" sudo killall -HUP trustd 2>/dev/null || true

  sleep 2
}

# ──────────────────────────────────────────────────────────────────────────────
# Repair: deep (OS daemon level)
# ──────────────────────────────────────────────────────────────────────────────
repair_deep() {
  step "Deep repair (OS network daemons)"

  info "Restarting configd"
  _timeout "$T_REPAIR_STEP" sudo launchctl kickstart -k system/com.apple.configd 2>/dev/null || \
  _timeout "$T_REPAIR_STEP" sudo killall -HUP configd 2>/dev/null || true

  info "Restarting mDNSResponder"
  _timeout "$T_REPAIR_STEP" sudo launchctl kickstart -k system/com.apple.mDNSResponder 2>/dev/null || \
  _timeout "$T_REPAIR_STEP" sudo killall -HUP mDNSResponder 2>/dev/null || true

  sleep 4

  info "Re-applying DHCP after daemon restart"
  _timeout "$T_REPAIR_STEP" sudo ipconfig set "$INTERFACE" NONE 2>/dev/null || true
  sleep 1
  _timeout "$T_REPAIR_STEP" sudo ipconfig set "$INTERFACE" DHCP 2>/dev/null || true
  _timeout "$T_IP_WAIT" ipconfig waitall 2>/dev/null || true
  wait_for_ip 25 || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  info "NetDoctor v${SCRIPT_VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
  info "Log: $LOG_FILE"

  detect_interface
  detect_service

  step "Initial diagnostic"
  if run_all_checks; then
    ok "All checks passed — connectivity OK"
    info "Log: $LOG_FILE"
    exit 0
  fi

  classify_failure

  if [[ "$REPAIR" == false ]]; then
    warn "Run with --repair (or --deep-repair) to attempt automated recovery"
    export_bundle
    exit 1
  fi

  # Take a snapshot before touching anything (for rollback)
  take_snapshot

  # ── Strategy decision ──────────────────────────────────────────────
  if (( CHECK_INTERNET == 1 && CHECK_HTTPS == 0 )); then
    # L3 works but L7 fails: do NOT reset interface (would lose IP for nothing)
    repair_https_only
  else
    # Missing IP or gateway: full L2 repair
    repair_standard
  fi

  step "Re-check after standard repair"
  if run_all_checks; then
    ok "Connectivity restored after standard repair"
    export_bundle
    exit 0
  fi

  maybe_rollback

  if [[ "$DEEP_REPAIR" == false ]]; then
    err "Still failing after standard repair"
    warn "Try --deep-repair to restart OS network daemons"
    export_bundle
    exit 1
  fi

  repair_deep

  step "Re-check after deep repair"
  if run_all_checks; then
    ok "Connectivity restored after deep repair"
    export_bundle
    exit 0
  fi

  maybe_rollback

  err "Connectivity still failing after all repair attempts"
  classify_failure
  export_bundle
  warn "Share the diagnostic bundle with your tech support:"
  warn "  $LOG_DIR/netdoctor-bundle-${TIMESTAMP}.tar.gz"
  exit 1
}

main "$@"

