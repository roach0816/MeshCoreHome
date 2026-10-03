#!/usr/bin/env bash
# MeshCore Home — installer, upgrader and uninstaller for Debian-based systems
# (Raspberry Pi OS / Debian 12 "bookworm", Debian 13 "trixie"; 64-bit ARM or x86-64).
#
#   Install (latest release):
#     curl -fsSLo install.sh https://github.com/roach0816/MeshCoreHome/releases/latest/download/install.sh
#     sudo bash install.sh
#
#   Options:
#     --version X.Y.Z    install/upgrade to a specific release (default: latest)
#     --from-file PATH   install from a local meshcore-home-X.Y.Z.tar.gz (offline / testing)
#     --port N           HTTP port for a fresh install (default 8080)
#     --yes              answer "yes" to every prompt (unattended)
#     --upgrade          upgrade an existing install (also chosen automatically when one exists)
#     --from-request     web-UI upgrade: read the requested version from the state directory and
#                        report progress there (run by meshcore-home-update.service, never by hand)
#     --uninstall [--purge]   remove the app; --purge also deletes the database, config and data
#     --https            set up (or redo) HTTPS on an existing install: nginx + Let's Encrypt via
#                        Cloudflare DNS validation (also offered at the end of a fresh install)
#     --https-disable    remove the HTTPS front end and serve plain HTTP again
#     --security-updates turn on Debian's automatic security updates (unattended-upgrades)
#
# Everything the script changes is listed on screen and confirmed first. Answering "n" to any
# confirmation cancels the installation.
set -Eeuo pipefail
umask 022

# ---- constants -----------------------------------------------------------------------------
APP_NAME="MeshCore Home"
REPO="${MESHCORE_HOME_REPO:-roach0816/MeshCoreHome}"
PREFIX=/opt/meshcore-home
CONF_DIR=/etc/meshcore-home
ENV_FILE=$CONF_DIR/meshcore-home.env
STATE_DIR=/var/lib/meshcore-home
BACKUP_DIR=$STATE_DIR/backups
LOG_FILE=/var/log/meshcore-home-install.log
APP_USER=meshcore
DB_NAME=meshcore
SERVICE=meshcore-home
UNIT_DIR=/etc/systemd/system
CLI_LINK=/usr/local/bin/meshcore-home
DEFAULT_PORT=8080
KEEP_RELEASES=2
KEEP_BACKUPS=5
REQUIRED_PACKAGES=(python3 python3-venv postgresql postgresql-client curl ca-certificates tar)
# Optional HTTPS: nginx in front of the app with a Let's Encrypt certificate obtained through a
# Cloudflare DNS-01 challenge (works for private/LAN-only hosts; nothing is exposed publicly).
HTTPS_PACKAGES=(nginx certbot python3-certbot-dns-cloudflare openssl)
NGINX_SITE=/etc/nginx/sites-available/meshcore-home
CF_CREDENTIALS=/etc/letsencrypt/meshcore-home-cloudflare.ini

# Test/mirror overrides (also read from $ENV_FILE on upgrades, which is root-owned).
API_URL="${MESHCORE_HOME_API:-https://api.github.com}"
DOWNLOAD_BASE="${MESHCORE_HOME_DOWNLOAD_BASE:-}"

# ---- arguments -----------------------------------------------------------------------------
WANT_VERSION="" FROM_FILE="" PORT="" ASSUME_YES=0 MODE="" FROM_REQUEST=0 PURGE=0 REPAIR=0
HTTPS_HOST="${MESHCORE_HOME_HTTPS_HOST:-}" HTTPS_EMAIL="${MESHCORE_HOME_HTTPS_EMAIL:-}"
while (($#)); do
  case "$1" in
    --version) WANT_VERSION="${2:?--version needs a value}"; shift ;;
    --from-file) FROM_FILE="${2:?--from-file needs a path}"; shift ;;
    --port) PORT="${2:?--port needs a value}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    --upgrade) MODE=upgrade ;;
    --from-request) MODE=upgrade; FROM_REQUEST=1; ASSUME_YES=1 ;;
    --uninstall) MODE=uninstall ;;
    --https) MODE=https ;;
    --https-disable) MODE=https-disable ;;
    --https-host) HTTPS_HOST="${2:?--https-host needs a value}"; shift ;;
    --security-updates) MODE=security-updates ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---- terminal UI ---------------------------------------------------------------------------
if [[ -t 1 && $FROM_REQUEST -eq 0 ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
else
  B="" D="" R="" G="" Y="" C="" N=""
fi
TTY_IN=/dev/tty
STEP=0 STEPS=0 STEP_TITLES=()
STATUS_FILE="$STATE_DIR/update-status.json"
TARGET_VERSION=""

# Locale-independent (byte-safe) drawing helpers: minimal systems often have no UTF-8 locale,
# where bash string slicing and `tr` work on bytes and would split multibyte characters.
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
repeat() { local i out=""; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
say() { printf '%s\n' "$*"; log "$*"; }
ok() { say "  ${G}✓${N} $*"; }
info() { say "  ${C}•${N} $*"; }
warn() { say "  ${Y}!${N} $*"; }

status() {  # status STATE MESSAGE — progress for web-UI upgrades (read by the app)
  ((FROM_REQUEST)) || return 0
  python3 - "$STATUS_FILE" "$1" "$TARGET_VERSION" "$2" "$LOG_FILE" <<'PY' || true
import json, os, sys, time
path, state, version, message, logf = sys.argv[1:6]
try:
    tail = open(logf, errors="replace").read().splitlines()[-15:]
except OSError:
    tail = []
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"state": state, "version": version, "message": message, "log_tail": tail,
               "updated_at": time.time()}, f)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
}

die() {
  local msg="$1" hint="${2:-}"
  printf '\n  %s✗ %s%s\n' "$R$B" "$msg" "$N" >&2
  [[ -n $hint ]] && printf '    %s\n' "$hint" >&2
  printf '    %sFull log: %s%s\n\n' "$D" "$LOG_FILE" "$N" >&2
  log "FAILED: $msg"
  status failed "$msg"
  exit 1
}
on_err() {
  # Command substitutions inherit this trap (set -E); let the main shell report the failure once.
  ((BASH_SUBSHELL == 0)) || return 0
  die "Unexpected error on line $1" "Re-run the installer; it is safe to run again."
}
trap 'on_err $LINENO' ERR
trap 'printf "\n"; die "Interrupted"' INT

banner() {
  printf '\n%s' "$C$B"
  cat <<'ART'
   __  __           _      ____                  _   _
  |  \/  | ___  ___| |__  / ___|___  _ __ ___   | | | | ___  _ __ ___   ___
  | |\/| |/ _ \/ __| '_ \| |   / _ \| '__/ _ \  | |_| |/ _ \| '_ ` _ \ / _ \
  | |  | |  __/\__ \ | | | |__| (_) | | |  __/  |  _  | (_) | | | | | |  __/
  |_|  |_|\___||___/_| |_|\____\___/|_|  \___|  |_| |_|\___/|_| |_| |_|\___|
ART
  printf '%s\n' "$N"
}

plan() {  # plan "Title 1" "Title 2" ... — declares the wizard's steps
  STEP_TITLES=("$@"); STEPS=$#; STEP=0
  printf '  %sThis will:%s\n' "$B" "$N"
  local i=1 t
  for t in "$@"; do printf '    %s%d.%s %s\n' "$D" "$i" "$N" "$t"; i=$((i + 1)); done
  printf '\n'
}

step() {  # step — advance to the next declared step and draw the overall progress bar
  STEP=$((STEP + 1))
  local title="${STEP_TITLES[$((STEP - 1))]}" width=24 filled
  filled=$((STEP * width / STEPS))
  printf '\n%s[%s%s]%s %sStep %d of %d%s  %s%s%s\n' "$C" \
    "$(repeat █ "$filled")" "$(repeat ░ $((width - filled)))" "$N" \
    "$D" "$STEP" "$STEPS" "$N" "$B" "$title" "$N"
  log "== Step $STEP/$STEPS: $title"
}

confirm() {  # confirm "Question" — Y/n; "n" cancels the whole installation
  local answer
  if ((ASSUME_YES)); then log "auto-yes: $1"; return 0; fi
  if [[ ! -r $TTY_IN ]] || ! { : <"$TTY_IN"; } 2>/dev/null; then
    die "No terminal available to ask: $1" "Run the installer from a terminal, or pass --yes."
  fi
  while true; do
    printf '\n  %s%s%s [Y/n] ' "$B" "$1" "$N"
    read -r answer <"$TTY_IN" || answer=n
    case "${answer,,}" in
      ""|y|yes) log "confirmed: $1"; return 0 ;;
      n|no)
        printf '\n  %sInstallation cancelled.%s Nothing further was changed.\n\n' "$Y" "$N"
        log "cancelled at: $1"
        exit 1 ;;
      *) printf '  Please answer y or n.\n' ;;
    esac
  done
}

ask_yn() {  # ask_yn "Question" y|n — returns 0 for yes; never cancels the installer
  local answer def=$2
  if ((ASSUME_YES)); then [[ $def == y ]]; return; fi
  [[ -r $TTY_IN ]] || { [[ $def == y ]]; return; }
  while true; do
    printf '\n  %s%s%s %s ' "$B" "$1" "$N" "$([[ $def == y ]] && echo '[Y/n]' || echo '[y/N]')" >/dev/tty
    read -r answer <"$TTY_IN" || answer=""
    case "${answer,,}" in
      "") [[ $def == y ]]; return ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '  Please answer y or n.\n' >/dev/tty ;;
    esac
  done
}

ask_secret() {  # ask_secret "Prompt" — hidden input (not echoed, not logged)
  local answer
  [[ -r $TTY_IN ]] || { printf ''; return; }
  printf '  %s%s%s ' "$B" "$1" "$N" >/dev/tty
  read -rs answer <"$TTY_IN" || true
  printf '\n' >/dev/tty
  printf '%s' "$answer"
}

ask() {  # ask "Question" DEFAULT — free-text answer (returns default under --yes)
  local answer
  if ((ASSUME_YES)) || [[ ! -r $TTY_IN ]]; then printf '%s' "$2"; return; fi
  if [[ -n $2 ]]; then printf '  %s%s%s [%s] ' "$B" "$1" "$N" "$2" >/dev/tty; else printf '  %s%s%s ' "$B" "$1" "$N" >/dev/tty; fi
  read -r answer <"$TTY_IN" || true
  printf '%s' "${answer:-$2}"
}

run() {  # run "Message" cmd... — runs quietly with a spinner, output goes to the log
  local msg="$1"; shift
  log "\$ $*"
  if [[ ! -t 1 || $FROM_REQUEST -eq 1 ]]; then
    "$@" >>"$LOG_FILE" 2>&1 || { tail -n 20 "$LOG_FILE" | sed 's/^/    /' >&2; die "$msg failed"; }
    ok "$msg"; return
  fi
  "$@" >>"$LOG_FILE" 2>&1 &
  local pid=$! i=0 start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s %s(%ss)%s' "$C" "${SPIN[i++ % 10]}" "$N" "$msg" "$D" $((SECONDS - start)) "$N"
    sleep 0.1
  done
  if wait "$pid"; then
    printf '\r\e[K'; ok "$msg ${D}($((SECONDS - start))s)${N}"
  else
    printf '\r\e[K'; tail -n 20 "$LOG_FILE" | sed 's/^/    /' >&2
    die "$msg failed"
  fi
}

bar() {  # bar PERCENT LABEL — single-line progress bar
  local pct=${1%.*} width=30 filled
  ((pct > 100)) && pct=100
  filled=$((pct * width / 100))
  printf '\r  %s%s%s%s%s %3d%% %s\e[K' "$G" "$(repeat █ "$filled")" "$D" "$(repeat ░ $((width - filled)))" "$N" "$pct" "${2:0:40}"
}

# ---- helpers -------------------------------------------------------------------------------
installed_version() { if [[ -f $PREFIX/current/VERSION ]]; then tr -d '[:space:]' <"$PREFIX/current/VERSION"; fi; }

version_gt() {  # version_gt A B — true if A > B (semver X.Y.Z)
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

env_get() { if [[ -f $ENV_FILE ]]; then sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; fi; }

json_field() {  # json_field FIELD < json
  python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$1"
}

download_base() { printf '%s' "${DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"; }

latest_version() {  # parsed with sed so it works before python3 is installed
  local tag
  tag=$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
    "$API_URL/repos/$REPO/releases/latest" 2>>"$LOG_FILE" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -n1) || true
  valid_version "$tag" && printf '%s' "$tag"
}

missing_packages() {  # missing_packages PKG... — prints those not installed
  local p
  for p in "$@"; do
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)" == installed ]] || printf '%s\n' "$p"
  done
}

lan_addresses() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n 3; }

wait_healthy() {  # wait_healthy PORT EXPECTED_VERSION TIMEOUT
  local port=$1 want=$2 deadline=$((SECONDS + $3)) v restarts
  while ((SECONDS < deadline)); do
    # Give up early if systemd is crash-looping the service (NRestarts resets on a manual restart).
    restarts=$(systemctl show -p NRestarts --value "$SERVICE" 2>/dev/null || echo 0)
    if [[ ${restarts:-0} -ge 2 ]] || systemctl is-failed --quiet "$SERVICE"; then
      log "service is crash-looping (restarts=$restarts)"
      return 1
    fi
    if curl -fsS --max-time 3 "http://127.0.0.1:$port/health/ready" >/dev/null 2>&1; then
      v=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/api/setup/status" 2>/dev/null | json_field version || true)
      [[ -z $want || $v == "$want" ]] && return 0
    fi
    sleep 2
  done
  return 1
}

# ---- steps ---------------------------------------------------------------------------------
preflight() {

  [[ -r /etc/os-release ]] || die "Cannot identify this operating system"
  # shellcheck disable=SC1091
  . /etc/os-release
  local arch; arch=$(uname -m)
  case "${ID:-}:${VERSION_CODENAME:-}" in
    debian:bookworm|debian:trixie|raspbian:bookworm|raspbian:trixie) ok "Operating system: ${PRETTY_NAME:-$ID}" ;;
    *)
      if [[ " ${ID_LIKE:-} " == *" debian "* || ${ID:-} == debian ]]; then
        warn "Untested OS: ${PRETTY_NAME:-unknown}. Supported: Raspberry Pi OS / Debian 12 (bookworm) and 13 (trixie)."
        confirm "Continue anyway?"
      else
        die "Unsupported operating system: ${PRETTY_NAME:-unknown}" "This installer supports Debian-based systems only."
      fi ;;
  esac
  case "$arch" in
    aarch64|x86_64) ok "Architecture: $arch" ;;
    armv7l|armv6l) die "A 64-bit operating system is required (found 32-bit $arch)" \
      "Re-image the Pi with Raspberry Pi OS (64-bit) using Raspberry Pi Imager." ;;
    *) die "Unsupported CPU architecture: $arch" ;;
  esac
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die "systemd is required but not running"
  ok "systemd is running"

  local mem_mb disk_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  ((mem_mb >= 900)) && ok "Memory: ${mem_mb} MB" || warn "Memory: ${mem_mb} MB (1 GB or more recommended)"
  disk_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  ((disk_mb >= 1500)) || die "Not enough free disk space (${disk_mb} MB free, 1.5 GB needed)"
  ok "Free disk space: ${disk_mb} MB"

  if [[ -z $FROM_FILE ]]; then
    if ! command -v curl >/dev/null; then
      warn "curl is needed to download $APP_NAME but is not installed."
      printf '\n  %sThis will run:%s apt-get update && apt-get install curl ca-certificates\n' "$B" "$N"
      confirm "Install curl?"
      run "Refreshing package lists" apt-get update
      run "Installing curl" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates
    fi
    curl -fsS --max-time 15 -o /dev/null "$API_URL" >>"$LOG_FILE" 2>&1 ||
      die "Cannot reach $API_URL" "Check the Pi's internet connection and DNS."
    ok "Internet access to GitHub"
  fi
  local cur; cur=$(installed_version || true)
  [[ $MODE == upgrade && -n $cur ]] && info "Installed: v$cur"
  return 0
}

choose_version() {
  local cur; cur=$(installed_version || true)
  if [[ -n $FROM_FILE ]]; then
    [[ -f $FROM_FILE ]] || die "File not found: $FROM_FILE"
    TARGET_VERSION=$(basename "$FROM_FILE" | sed -n 's/^meshcore-home-\([0-9.]*\)\.tar\.gz$/\1/p')
    valid_version "$TARGET_VERSION" || die "Unexpected package name: $(basename "$FROM_FILE")"
    ok "Package: $FROM_FILE (v$TARGET_VERSION)"
  else
    if [[ -n $WANT_VERSION ]]; then
      TARGET_VERSION=${WANT_VERSION#v}
      valid_version "$TARGET_VERSION" || die "Invalid version: $WANT_VERSION"
    else
      TARGET_VERSION=$(latest_version) || die "Could not look up the latest release of $REPO"
    fi
    ok "Release: v$TARGET_VERSION  ${D}https://github.com/$REPO/releases/tag/v$TARGET_VERSION${N}"
  fi
  if [[ $MODE == upgrade ]]; then
    if [[ $TARGET_VERSION == "$cur" ]]; then
      local port; port=$(env_get PORT); port=${port:-$DEFAULT_PORT}
      if systemctl is-active --quiet "$SERVICE" && wait_healthy "$port" "$cur" 5; then
        ok "v$cur is already installed and running — nothing to do."
        status "done" "Already up to date (v$cur)"
        exit 0
      fi
      ((FROM_REQUEST)) && die "v$cur is installed but not running" "Repair it from a terminal: sudo meshcore-home update"
      warn "v$cur is installed but not running correctly."
      confirm "Repair the installation by reinstalling v$cur?"
      REPAIR=1
      return
    fi
    version_gt "$TARGET_VERSION" "$cur" ||
      die "v$TARGET_VERSION is older than the installed v$cur" "Downgrades are not supported by the installer."
    info "Upgrade: v$cur → v$TARGET_VERSION"
  fi
}

install_packages() {
  local missing; mapfile -t missing < <(missing_packages "${REQUIRED_PACKAGES[@]}")
  if ((${#missing[@]} == 0)); then ok "All required system packages are already installed"; return; fi
  ((FROM_REQUEST)) && die "This version needs new system packages (${missing[*]})" \
    "Upgrade from a terminal instead: sudo meshcore-home update"
  apt_review_install "Install these packages?" cancel "${missing[@]}"
}

# apt_review_install QUESTION ON_DECLINE PKG... — show exactly what apt will install (with
# dependencies, versions and sizes), ask, then install with a progress bar.
# ON_DECLINE: "cancel" ends the installer; "skip" returns 1 so the caller can carry on without.
apt_review_install() {
  local question=$1 on_decline=$2; shift 2
  local -a missing=("$@")

  info "Refreshing package lists (apt-get update) to see exactly what would be installed…"
  run "Refreshing package lists" apt-get update

  # Simulate to list every package apt would add, including dependencies.
  local sim
  if ! sim=$(LC_ALL=C apt-get -s install --no-install-recommends "${missing[@]}" 2>>"$LOG_FILE"); then
    die "apt cannot install: ${missing[*]}" "See the log; your package sources may be incomplete."
  fi
  local -a inst; mapfile -t inst < <(sed -n 's/^Inst \([^ ]*\) .*(\([^ ]*\) .*/\1 \2/p' <<<"$sim")
  local size; size=$({ LC_ALL=C apt-get install --no-install-recommends --assume-no "${missing[@]}" 2>/dev/null || true; } |
    sed -n 's/^\(Need to get .*\)\.$/\1/p;s/^\(After this operation, .*\)\.$/\1/p' | paste -sd ';' - | sed 's/;/; /')

  printf '\n  %sThe following system packages will be installed with apt:%s\n' "$B" "$N"
  local line name ver desc
  for line in "${inst[@]}"; do
    name=${line%% *}; ver=${line#* }
    if printf '%s\n' "${missing[@]}" | grep -qx "$name"; then
      desc=$(apt-cache show --no-all-versions "$name" 2>/dev/null | sed -n 's/^Description\(-en\)\{0,1\}: //p' | head -n1)
      printf '    %s%-28s%s %s%-22s%s %s\n' "$B" "$name" "$N" "$D" "$ver" "$N" "$desc"
    fi
  done
  local deps=$((${#inst[@]} - ${#missing[@]}))
  if ((deps > 0)); then
    printf '    %splus %d supporting package(s): %s%s\n' "$D" "$deps" \
      "$(for line in "${inst[@]}"; do n=${line%% *}; printf '%s\n' "${missing[@]}" | grep -qx "$n" || printf '%s ' "$n"; done)" "$N"
  fi
  [[ -n $size ]] && printf '    %s%s%s\n' "$D" "$size" "$N"
  if [[ $on_decline == skip ]]; then
    ask_yn "$question" y || return 1
  else
    confirm "$question"
  fi

  # apt reports progress on fd 3 as "pmstatus:package:percent:description". Its exit code is
  # captured in a file so the progress-drawing loop can never mask (or fake) a failure.
  log "\$ apt-get install ${missing[*]}"
  local rcfile; rcfile=$(mktemp)
  { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o APT::Status-Fd=3 \
      "${missing[@]}" 3>&1 1>>"$LOG_FILE" 2>&1; echo $? >"$rcfile"; } |
    while IFS=: read -r kind _pkg pct desc; do
      if [[ -t 1 && ($kind == pmstatus || $kind == dlstatus) ]]; then bar "$pct" "$desc"; fi
    done
  local rc; rc=$(cat "$rcfile"); rm -f "$rcfile"
  if [[ -t 1 ]]; then printf '\r\e[K'; fi
  [[ $rc == 0 ]] || { tail -n 20 "$LOG_FILE" | sed 's/^/    /' >&2; die "Package installation failed"; }
  ok "Installed: ${missing[*]}"
}

configure() {
  PORT=${PORT:-$(ask "Port for the web interface?" "$DEFAULT_PORT")}
  [[ $PORT =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "Invalid port: $PORT"
  if ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .; then
    die "Port $PORT is already in use" "Choose another with --port, or stop whatever is using it."
  fi
  printf '\n  %sThese changes will be made to this system:%s\n' "$B" "$N"
  printf '    • Create system user %s%s%s (no login, no home directory) to run the app\n' "$B" "$APP_USER" "$N"
  printf '    • Create %s (app), %s (config) and %s (data)\n' "$PREFIX" "$CONF_DIR" "$STATE_DIR"
  printf '    • Create PostgreSQL role and database %s%s%s (local socket, OS-user auth, no password)\n' "$B" "$DB_NAME" "$N"
  printf '    • Install systemd services %s%s%s (starts at boot) and %s-update (in-place upgrades)\n' "$B" "$SERVICE" "$N" "$SERVICE"
  printf '    • Install the %s%s%s command\n' "$B" "$CLI_LINK" "$N"
  printf '    • Serve the web interface on port %s%s%s (all network interfaces, plain HTTP)\n' "$B" "$PORT" "$N"
  confirm "Make these changes?"
}

fetch_package() {
  WORK=$(mktemp -d /tmp/meshcore-home.XXXXXX)
  trap 'rm -rf "$WORK"' EXIT
  local name="meshcore-home-$TARGET_VERSION.tar.gz"
  if [[ -n $FROM_FILE ]]; then
    cp "$FROM_FILE" "$WORK/$name"
    if [[ -f "$(dirname "$FROM_FILE")/SHA256SUMS" ]]; then cp "$(dirname "$FROM_FILE")/SHA256SUMS" "$WORK/"; fi
  else
    local base; base="$(download_base)/v$TARGET_VERSION"
    status downloading "Downloading v$TARGET_VERSION"
    log "\$ curl $base/$name"
    if [[ -t 1 && $FROM_REQUEST -eq 0 ]]; then
      curl -fL --retry 3 --progress-bar -o "$WORK/$name" "$base/$name" || die "Download failed: $base/$name"
    else
      curl -fsSL --retry 3 -o "$WORK/$name" "$base/$name" || die "Download failed: $base/$name"
    fi
    curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "$base/SHA256SUMS" || die "Download failed: $base/SHA256SUMS"
    ok "Downloaded $name ($(du -h "$WORK/$name" | cut -f1))"
  fi
  if [[ -f $WORK/SHA256SUMS ]]; then
    (cd "$WORK" && grep " $name\$" SHA256SUMS | sha256sum -c --status) ||
      die "Checksum mismatch for $name" "The download is corrupt or has been tampered with. Nothing was installed."
    ok "Checksum verified (SHA-256)"
  else
    warn "No SHA256SUMS next to the local file; skipping checksum verification"
  fi
}

ensure_user_and_dirs() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    run "Creating system user $APP_USER" useradd --system --user-group --no-create-home \
      --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  install -d -m 755 -o root -g root "$PREFIX" "$PREFIX/releases"
  install -d -m 750 -o root -g "$APP_USER" "$CONF_DIR"
  install -d -m 750 -o "$APP_USER" -g "$APP_USER" "$STATE_DIR" "$BACKUP_DIR"
  ok "Directories ready"
}

install_release() {
  local dest="$PREFIX/releases/$TARGET_VERSION"
  status installing "Installing v$TARGET_VERSION"
  if [[ "$(readlink -f "$PREFIX/current" 2>/dev/null)" == "$dest" ]]; then
    ((REPAIR)) || die "v$TARGET_VERSION is already the active release"
    systemctl stop "$SERVICE" >>"$LOG_FILE" 2>&1 || true
  fi
  # Build in place at the final path: Python virtualenvs are not relocatable (their scripts
  # hard-code the path), so the directory must not be renamed afterwards. A leftover from an
  # interrupted attempt is simply rebuilt; it only becomes live when `current` points at it.
  rm -rf "$dest" "$dest.partial"
  mkdir -p "$dest"
  run "Unpacking v$TARGET_VERSION" tar -xzf "$WORK/meshcore-home-$TARGET_VERSION.tar.gz" \
    -C "$dest" --strip-components=1 --no-same-owner
  [[ "$(tr -d '[:space:]' <"$dest/VERSION")" == "$TARGET_VERSION" ]] || die "Package version does not match"
  run "Creating Python environment" python3 -m venv "$dest/venv"
  run "Installing Python packages (this can take a few minutes on a Pi)" \
    "$dest/venv/bin/python" -m pip install --no-cache-dir --disable-pip-version-check --only-binary=:all: \
    -r "$dest/requirements.txt"
  run "Precompiling" "$dest/venv/bin/python" -m compileall -q "$dest/app" "$dest/migrations"
  chmod 755 "$dest/deploy/native/install.sh" "$dest/deploy/native/meshcore-home" "$dest/deploy/native/tls-hook"
  ok "v$TARGET_VERSION installed to $dest"
}

ensure_database() {
  systemctl enable --now postgresql >>"$LOG_FILE" 2>&1 || die "Could not start PostgreSQL"
  local i
  for i in $(seq 1 30); do runuser -u postgres -- pg_isready -q 2>/dev/null && break; sleep 1; done
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'" | grep -q 1; then
    run "Creating database role $APP_USER" runuser -u postgres -- createuser "$APP_USER"
  fi
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    run "Creating database $DB_NAME" runuser -u postgres -- createdb -O "$APP_USER" "$DB_NAME"
  fi
  ok "PostgreSQL database ready ($(runuser -u postgres -- psql -tAc 'SHOW server_version' | cut -d' ' -f1))"
}

write_env() {
  if [[ -f $ENV_FILE ]]; then ok "Keeping existing configuration $ENV_FILE"; return; fi
  cat >"$ENV_FILE" <<EOF
# MeshCore Home (native install). Created by install.sh; keep this file private.
# The owner account and radio settings live in the database (first-run setup wizard).
DATABASE_URL=postgresql+asyncpg://$APP_USER@/$DB_NAME?host=/var/run/postgresql
HOST=0.0.0.0
PORT=$PORT
MESHCORE_INSTALL_KIND=native
MESHCORE_STATE_DIR=$STATE_DIR
STATIC_DIR=$PREFIX/current/static
UPDATE_REPO=$REPO
LOG_LEVEL=INFO
EOF
  chown root:"$APP_USER" "$ENV_FILE"; chmod 640 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
}

install_units() {  # from the release being activated
  local src="$PREFIX/releases/$TARGET_VERSION/deploy/native/systemd" u
  for u in "$SERVICE.service" "$SERVICE-update.service" "$SERVICE-update.path"; do
    install -m 644 "$src/$u" "$UNIT_DIR/$u"
  done
  systemctl daemon-reload
  ln -sfn "$PREFIX/current/deploy/native/meshcore-home" "$CLI_LINK"
}

activate() {  # switch current -> new release and (re)start, rolling back on failure
  local new="$PREFIX/releases/$TARGET_VERSION" prev=""
  [[ -L $PREFIX/current ]] && prev=$(readlink -f "$PREFIX/current")
  PORT=${PORT:-$(env_get PORT)}; PORT=${PORT:-$DEFAULT_PORT}
  status restarting "Restarting on v$TARGET_VERSION"
  ln -sfn "$new" "$PREFIX/current.new" && mv -T "$PREFIX/current.new" "$PREFIX/current"
  install_units
  systemctl enable "$SERVICE.service" "$SERVICE-update.path" >>"$LOG_FILE" 2>&1
  systemctl start "$SERVICE-update.path" >>"$LOG_FILE" 2>&1 || true
  if ! systemctl restart "$SERVICE.service" >>"$LOG_FILE" 2>&1; then
    warn "$SERVICE failed to start"
  elif run_check "Started; waiting for v$TARGET_VERSION to become ready" wait_healthy "$PORT" "$TARGET_VERSION" 120; then
    return 0
  fi
  journalctl -u "$SERVICE" -n 30 --no-pager >>"$LOG_FILE" 2>&1 || true
  if [[ -z $prev ]]; then
    # First install: undo activation so simply re-running the installer starts over cleanly.
    systemctl disable --now "$SERVICE.service" >>"$LOG_FILE" 2>&1 || true
    rm -f "$PREFIX/current"
    die "$APP_NAME did not start" "Details: journalctl -u $SERVICE -n 50   (then re-run the installer)"
  fi
  if [[ -n $prev && -d $prev && $prev != "$new" ]]; then
    local prev_v; prev_v=$(basename "$prev")
    warn "v$TARGET_VERSION did not start; rolling back to v$prev_v"
    ln -sfn "$prev" "$PREFIX/current.new" && mv -T "$PREFIX/current.new" "$PREFIX/current"
    local failed=$TARGET_VERSION; TARGET_VERSION=$prev_v
    install_units
    TARGET_VERSION=$failed
    systemctl restart "$SERVICE.service" >>"$LOG_FILE" 2>&1 || true
    if wait_healthy "$PORT" "$prev_v" 90; then
      rm -rf "$new"  # discard the release that failed
      log "rolled back to v$prev_v"
      status rolled_back "v$failed didn't start, so v$prev_v was restored automatically. Nothing was lost."
      printf '\n  %s✗ Upgrade to v%s failed — v%s was restored and is running.%s\n' "$R$B" "$failed" "$prev_v" "$N" >&2
      printf '    %sDetails: journalctl -u %s   Full log: %s%s\n\n' "$D" "$SERVICE" "$LOG_FILE" "$N" >&2
      exit 1
    fi
  fi
  die "$APP_NAME did not start" "Check: journalctl -u $SERVICE -n 50"
}

run_check() {  # like run(), but returns non-zero instead of exiting
  local msg="$1"; shift
  if "$@"; then ok "$msg"; return 0; fi
  warn "$msg — timed out"; return 1
}

backup_database() {
  status installing "Backing up the database"
  local f; f="$BACKUP_DIR/pre-upgrade-$(installed_version)-$(date +%Y%m%dT%H%M%S).dump"
  run "Backing up the database to $f" runuser -u "$APP_USER" -- pg_dump -Fc -f "$f" "$DB_NAME"
  # Keep the newest few pre-upgrade backups.
  { ls -1t "$BACKUP_DIR"/pre-upgrade-*.dump 2>/dev/null || true; } | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
}

prune_releases() {
  local keep cur; cur=$(readlink -f "$PREFIX/current")
  keep=$(ls -1dt "$PREFIX"/releases/*/ 2>/dev/null | sed 's#/$##' | head -n "$KEEP_RELEASES")
  local d
  for d in "$PREFIX"/releases/*; do
    [[ -d $d && $d != "$cur" ]] || continue
    grep -qx "$d" <<<"$keep" || { rm -rf "$d"; log "pruned $d"; }
  done
}

finish() {
  local port; port=$(env_get PORT); port=${port:-$DEFAULT_PORT}
  status "done" "Upgraded to v$TARGET_VERSION"
  printf '\n  %s%s✓ %s v%s is running.%s\n\n' "$G" "$B" "$APP_NAME" "$TARGET_VERSION" "$N"
  local https_host; https_host=$(env_get HTTPS_HOST)
  if [[ -n $https_host ]]; then
    printf '  Open it from a browser on your network:\n    %shttps://%s%s\n' "$B" "$https_host" "$N"
    printf '  %sMake sure %s resolves to this Pi on your network (local DNS or router), e.g. %s%s\n' \
      "$D" "$https_host" "$(lan_addresses | head -n1)" "$N"
  else
    printf '  Open it from a browser on your network:\n'
    local ip; for ip in $(lan_addresses); do printf '    %shttp://%s:%s%s\n' "$B" "$ip" "$port" "$N"; done
    printf '    %shttp://%s.local:%s%s\n' "$D" "$(hostname)" "$port" "$N"
    printf '  %sPlain HTTP. Add a trusted HTTPS certificate any time: sudo meshcore-home https%s\n' "$D" "$N"
  fi
  if [[ -f $STATE_DIR/setup-token ]]; then
    printf '\n  First-run setup token (the wizard asks for it): %s%s%s\n' "$B$Y" "$(cat "$STATE_DIR/setup-token")" "$N"
  fi
  printf '\n  Manage it with: %smeshcore-home status | logs | update | backup | https | uninstall%s\n\n' "$B" "$N"
}

uninstall() {
  [[ $EUID -eq 0 ]] || die "Please run as root" "sudo meshcore-home uninstall"
  printf '\n  %sThis will remove:%s\n' "$B" "$N"
  printf '    • The %s services and the %s command\n' "$SERVICE" "$CLI_LINK"
  printf '    • The application files in %s\n' "$PREFIX"
  [[ -f $NGINX_SITE ]] && printf '    • The nginx HTTPS site for %s (nginx itself stays installed)\n' "$(env_get HTTPS_HOST)"
  if ((PURGE)); then
    printf '    • %sThe database %s (all message history), %s and %s%s\n' "$R" "$DB_NAME" "$CONF_DIR" "$STATE_DIR" "$N"
    printf '    • The system user %s\n' "$APP_USER"
    [[ -f $CF_CREDENTIALS ]] && printf '    • The saved Cloudflare API token (%s)\n' "$CF_CREDENTIALS"
  else
    printf '  %sKept:%s the database, %s and %s (use --purge to delete them too)\n' "$B" "$N" "$CONF_DIR" "$STATE_DIR"
  fi
  printf '  %sSystem packages (PostgreSQL, Python) are left installed.%s\n' "$D" "$N"
  confirm "Uninstall $APP_NAME?"
  systemctl disable --now "$SERVICE-update.path" "$SERVICE.service" >>"$LOG_FILE" 2>&1 || true
  rm -f "$UNIT_DIR/$SERVICE.service" "$UNIT_DIR/$SERVICE-update.service" "$UNIT_DIR/$SERVICE-update.path" "$CLI_LINK"
  systemctl daemon-reload
  rm -rf "$PREFIX"
  if [[ -f $NGINX_SITE || -L /etc/nginx/sites-enabled/meshcore-home ]]; then
    rm -f /etc/nginx/sites-enabled/meshcore-home "$NGINX_SITE"
    systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
  fi
  if ((PURGE)); then
    rm -f "$CF_CREDENTIALS"
    runuser -u postgres -- dropdb --if-exists "$DB_NAME" >>"$LOG_FILE" 2>&1 || true
    runuser -u postgres -- dropuser --if-exists "$APP_USER" >>"$LOG_FILE" 2>&1 || true
    rm -rf "$CONF_DIR" "$STATE_DIR"
    userdel "$APP_USER" >>"$LOG_FILE" 2>&1 || true
  fi
  printf '\n  %s✓ %s has been removed.%s\n\n' "$G" "$APP_NAME" "$N"
}

# ---- optional HTTPS (nginx + Let's Encrypt via Cloudflare DNS-01) ---------------------------
env_set() {  # env_set KEY VALUE — add or replace a line in the env file
  if grep -q "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
  fi
}

port_owner() {  # port_owner PORT — name of the process listening on it, if any
  ss -Hltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1
}

run_quiet() {  # like run(), but returns non-zero instead of exiting
  local msg="$1"; shift
  log "\$ $*"
  if "$@" >>"$LOG_FILE" 2>&1; then ok "$msg"; return 0; fi
  warn "$msg — failed"; return 1
}

https_setup() {  # returns 1 (without exiting) if HTTPS could not be set up; the app stays on HTTP
  local port; port=$(env_get PORT); port=${port:-$DEFAULT_PORT}
  printf '\n  HTTPS puts nginx in front of %s with a trusted Let'"'"'s Encrypt certificate.\n' "$APP_NAME"
  printf '  The certificate is validated through %sCloudflare DNS%s, so the Pi does not need to be\n' "$B" "$N"
  printf '  reachable from the internet. You need a domain whose DNS is managed by Cloudflare.\n'

  local fqdn_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  while true; do
    HTTPS_HOST=${HTTPS_HOST:-$(ask "Hostname for the app (e.g. meshcore.example.com)?" "")}
    HTTPS_HOST=${HTTPS_HOST,,}
    [[ $HTTPS_HOST =~ $fqdn_re ]] && break
    if ((ASSUME_YES)) || [[ ! -r $TTY_IN ]]; then warn "Invalid or missing hostname for HTTPS"; return 1; fi
    warn "Enter a full hostname such as meshcore.example.com"; HTTPS_HOST=""
  done
  HTTPS_EMAIL=${HTTPS_EMAIL:-$(ask "Email for Let's Encrypt expiry notices (optional)?" "")}

  # Ports 80/443 must be free or already served by nginx.
  local p owner
  for p in 80 443; do
    owner=$(port_owner "$p")
    if [[ -n $owner && $owner != nginx ]]; then
      warn "Port $p is already used by '$owner'; HTTPS needs ports 80 and 443. Nothing was changed."
      return 1
    fi
  done

  local token=""
  if [[ -z ${MESHCORE_HOME_TLS_SELF_SIGNED:-} ]]; then
    printf '\n  Create a Cloudflare API token at %shttps://dash.cloudflare.com/profile/api-tokens%s using\n' "$C" "$N"
    printf '  the %s"Edit zone DNS"%s template, limited to the zone that contains %s.\n' "$B" "$N" "$HTTPS_HOST"
    printf '  It is stored only in %s (root-only) and used for renewals.\n' "$CF_CREDENTIALS"
    if [[ -f $CF_CREDENTIALS ]] && ask_yn "Reuse the Cloudflare token saved earlier?" y; then
      token="(saved)"
    else
      token=${MESHCORE_HOME_CF_TOKEN:-$(ask_secret "Cloudflare API token (input hidden):")}
      [[ -n $token ]] || { warn "No Cloudflare token entered; HTTPS not set up."; return 1; }
    fi
  fi

  local missing; mapfile -t missing < <(missing_packages "${HTTPS_PACKAGES[@]}")
  if ((${#missing[@]})); then
    apt_review_install "Install these packages for HTTPS?" skip "${missing[@]}" ||
      { warn "HTTPS skipped; $APP_NAME stays on plain HTTP."; return 1; }
  else
    ok "nginx and certbot are already installed"
  fi

  printf '\n  %sThese changes will be made for HTTPS:%s\n' "$B" "$N"
  printf '    • Obtain a Let'"'"'s Encrypt certificate for %s%s%s (renewed automatically by certbot.timer)\n' "$B" "$HTTPS_HOST" "$N"
  printf '    • Add an nginx site on ports 80 and 443 for %s (port 80 redirects to HTTPS)\n' "$HTTPS_HOST"
  printf '    • Make %s listen on 127.0.0.1:%s only, so it is reached through nginx\n' "$APP_NAME" "$port"
  ask_yn "Set up HTTPS?" y || { warn "HTTPS skipped; $APP_NAME stays on plain HTTP."; return 1; }

  local cert key
  if [[ -n ${MESHCORE_HOME_TLS_SELF_SIGNED:-} ]]; then
    # Testing only: a self-signed certificate instead of Let's Encrypt (browsers will warn).
    warn "MESHCORE_HOME_TLS_SELF_SIGNED is set: using a self-signed TEST certificate"
    install -d -m 755 "$CONF_DIR/tls-test"
    cert="$CONF_DIR/tls-test/fullchain.pem" key="$CONF_DIR/tls-test/privkey.pem"
    run "Creating a self-signed test certificate" openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
      -subj "/CN=$HTTPS_HOST" -addext "subjectAltName=DNS:$HTTPS_HOST" -keyout "$key" -out "$cert"
    chmod 600 "$key"
  else
    if [[ $token != "(saved)" ]]; then
      install -d -m 700 "$(dirname "$CF_CREDENTIALS")"
      (umask 077; printf '# Cloudflare API token for certbot (MeshCore Home)\ndns_cloudflare_api_token = %s\n' "$token" >"$CF_CREDENTIALS")
    fi
    local -a certbot_args=(certonly --non-interactive --agree-tos --dns-cloudflare
      --dns-cloudflare-credentials "$CF_CREDENTIALS" --dns-cloudflare-propagation-seconds 30
      -d "$HTTPS_HOST" --cert-name "$HTTPS_HOST" --keep-until-expiring
      --deploy-hook "$PREFIX/current/deploy/native/tls-hook")
    if [[ -n $HTTPS_EMAIL ]]; then certbot_args+=(-m "$HTTPS_EMAIL"); else certbot_args+=(--register-unsafely-without-email); fi
    if [[ -n ${MESHCORE_HOME_CERTBOT_STAGING:-} ]]; then certbot_args+=(--test-cert); fi
    if ! run_quiet "Requesting a certificate from Let's Encrypt (the DNS check takes ~30s)" certbot "${certbot_args[@]}"; then
      tail -n 8 "$LOG_FILE" | sed 's/^/    /' >&2
      warn "Could not obtain a certificate. Check the token's permissions and that $HTTPS_HOST is in that Cloudflare zone."
      warn "$APP_NAME stays on plain HTTP. Try again any time with: sudo meshcore-home https"
      return 1
    fi
    cert="/etc/letsencrypt/live/$HTTPS_HOST/fullchain.pem" key="/etc/letsencrypt/live/$HTTPS_HOST/privkey.pem"
  fi

  cat >"$NGINX_SITE" <<NGINX
# MeshCore Home — HTTPS front end. Managed by install.sh (meshcore-home https).
map \$http_upgrade \$meshcore_connection_upgrade {
    default upgrade;
    ''      close;
}
server {
    listen 80;
    listen [::]:80;
    server_name $HTTPS_HOST;
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $HTTPS_HOST;

    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:meshcore_ssl:5m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 2m;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        # WebSocket (live updates)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$meshcore_connection_upgrade;
        proxy_read_timeout 1h;
    }
}
NGINX
  # nginx before 1.25 (Debian 12) has no "http2 on;" directive: use the older listen flag.
  if ! grep -qE 'nginx/1\.(2[5-9]|[3-9][0-9])' <<<"$(nginx -v 2>&1)"; then
    sed -i -e '/^    http2 on;$/d' -e 's/listen 443 ssl;/listen 443 ssl http2;/' \
      -e 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' "$NGINX_SITE"
  fi
  ln -sfn "$NGINX_SITE" /etc/nginx/sites-enabled/meshcore-home
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    rm -f /etc/nginx/sites-enabled/meshcore-home
    warn "nginx rejected the configuration (see $LOG_FILE); HTTPS not enabled."
    return 1
  fi
  systemctl enable nginx >>"$LOG_FILE" 2>&1 || true
  run "Starting nginx" systemctl reload-or-restart nginx

  env_set HOST 127.0.0.1
  env_set HTTPS_HOST "$HTTPS_HOST"
  env_set TLS_CERT "$cert"
  run "Restarting $APP_NAME behind nginx" systemctl restart "$SERVICE"
  wait_healthy "$port" "" 60 || { warn "$APP_NAME did not come back after switching to HTTPS"; return 1; }
  bash "$PREFIX/current/deploy/native/tls-hook" >>"$LOG_FILE" 2>&1 || true

  local -a k=()
  if [[ -n ${MESHCORE_HOME_TLS_SELF_SIGNED:-} ]]; then k=(-k); fi
  if curl -fsS "${k[@]}" --max-time 10 --resolve "$HTTPS_HOST:443:127.0.0.1" "https://$HTTPS_HOST/health/ready" >/dev/null 2>&1; then
    ok "HTTPS is working: https://$HTTPS_HOST"
  else
    warn "nginx is configured, but https://$HTTPS_HOST did not answer locally yet (see $LOG_FILE)"
  fi
  return 0
}

https_disable() {
  if [[ ! -f $NGINX_SITE && ! -L /etc/nginx/sites-enabled/meshcore-home ]]; then ok "HTTPS is not enabled"; return; fi
  printf '\n  %sThis will%s remove the nginx site for %s and make %s listen on all\n' "$B" "$N" "$(env_get HTTPS_HOST)" "$APP_NAME"
  printf '  interfaces over plain HTTP again. The certificate and saved Cloudflare token are kept.\n'
  confirm "Disable HTTPS?"
  rm -f /etc/nginx/sites-enabled/meshcore-home "$NGINX_SITE"
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
  env_set HOST 0.0.0.0
  sed -i '/^HTTPS_HOST=/d;/^TLS_CERT=/d' "$ENV_FILE"
  rm -f "$STATE_DIR/tls-status.json"
  run "Restarting $APP_NAME on plain HTTP" systemctl restart "$SERVICE"
  local port; port=$(env_get PORT); port=${port:-$DEFAULT_PORT}
  wait_healthy "$port" "" 60 || warn "$APP_NAME is slow to come back; check: meshcore-home status"
  ok "HTTPS disabled — $APP_NAME is on http://$(lan_addresses | head -n1):$port"
}

# ---- optional automatic OS security updates (Debian's unattended-upgrades) -------------------
security_updates_enabled() {
  # Here-strings, not pipes into `grep -q`: with pipefail, grep exiting early makes a long
  # producer (apt-config dump) die of SIGPIPE and the check would wrongly fail.
  local status conf
  status=$(dpkg-query -W -f='${db:Status-Status}' unattended-upgrades 2>/dev/null || true)
  conf=$(apt-config dump 2>/dev/null || true)
  [[ $status == installed ]] && grep -q '^APT::Periodic::Unattended-Upgrade "1";' <<<"$conf"
}

security_updates_setup() {  # returns 1 if skipped; never cancels the installer
  if security_updates_enabled; then ok "Automatic security updates are already enabled"; return 0; fi
  printf '\n  Debian can install %ssecurity updates%s for the operating system automatically\n' "$B" "$N"
  printf '  (unattended-upgrades) — recommended for an always-on Pi. It only applies security fixes from\n'
  printf '  your OS repositories; it never upgrades %s itself (you choose when to do that).\n' "$APP_NAME"
  ask_yn "Enable automatic security updates?" y || { info "Skipped. Enable later with: sudo meshcore-home security-updates"; return 1; }
  local missing; mapfile -t missing < <(missing_packages unattended-upgrades)
  if ((${#missing[@]})); then
    apt_review_install "Install this package?" skip "${missing[@]}" ||
      { info "Skipped. Enable later with: sudo meshcore-home security-updates"; return 1; }
  fi
  # Debian's documented way to switch it on (writes /etc/apt/apt.conf.d/20auto-upgrades).
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
  run "Enabling automatic security updates" env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades
  if security_updates_enabled; then
    ok "Security updates will be installed automatically (daily, via apt-daily-upgrade.timer)"
  else
    warn "unattended-upgrades is installed but not enabled; see $LOG_FILE"
    return 1
  fi
}

read_request() {  # web-UI upgrade: take the version from the request file written by the app
  local req="$STATE_DIR/update-request.json"
  [[ -f $req ]] || { log "no update request; nothing to do"; exit 0; }
  local v; v=$(json_field version <"$req" 2>/dev/null || true)
  rm -f "$req"
  valid_version "$v" || { TARGET_VERSION=""; die "Ignoring invalid update request"; }
  WANT_VERSION=$v
  # Mirror overrides live in the root-owned env file (never in the app-writable request).
  API_URL=$(env_get MESHCORE_HOME_API); API_URL=${API_URL:-https://api.github.com}
  DOWNLOAD_BASE=$(env_get MESHCORE_HOME_DOWNLOAD_BASE)
  local repo; repo=$(env_get UPDATE_REPO); REPO=${repo:-$REPO}
  TARGET_VERSION=$v
  status queued "Preparing to upgrade to v$v"
}

# ---- main ----------------------------------------------------------------------------------
main() {
  [[ $EUID -eq 0 ]] || { echo "Please run as root:  sudo bash $0" >&2; exit 1; }
  mkdir -p "$(dirname "$LOG_FILE")"; : >>"$LOG_FILE"; chmod 600 "$LOG_FILE"
  log "---- $APP_NAME installer started (args: mode=${MODE:-auto}) ----"

  if [[ $MODE == uninstall ]]; then uninstall; return; fi
  if [[ $MODE == security-updates ]]; then
    security_updates_setup || exit 1
    return
  fi
  if [[ $MODE == https || $MODE == https-disable ]]; then
    [[ -n $(installed_version) ]] || die "$APP_NAME is not installed"
    TARGET_VERSION=$(installed_version)
    if [[ $MODE == https-disable ]]; then https_disable; return; fi
    banner
    STEP_TITLES=("Set up HTTPS"); STEPS=1; step
    https_setup || exit 1
    finish
    return
  fi
  ((FROM_REQUEST)) && read_request

  local cur; cur=$(installed_version || true)
  if [[ -z $MODE ]]; then MODE=$([[ -n $cur ]] && echo upgrade || echo install); fi
  [[ $MODE == upgrade && -z $cur ]] && die "Nothing to upgrade: $APP_NAME is not installed" "Run without --upgrade to install."

  if [[ $MODE == upgrade ]]; then
    if ((FROM_REQUEST)); then
      STEP_TITLES=(Check Version Packages Backup Download Install Restart); STEPS=7
    else
      banner
      printf '  %s v%s is installed — this will upgrade it.\n\n' "$APP_NAME" "$cur"
      plan "Check this system" "Choose the version" "System packages" "Back up the database" \
        "Download and verify" "Install the new version" "Switch over and restart"
    fi
    step; preflight
    step; choose_version
    step; install_packages
    step; backup_database
    step; fetch_package
    step; install_release
    step; activate; prune_releases
    finish
    return
  fi

  banner
  plan "Check this system" "Choose the version" "System packages" "Review system changes" \
    "Download and verify" "Install the app" "Set up the database" "Start the service" "HTTPS (optional)" \
    "Automatic security updates (optional)"
  step; preflight
  step; choose_version
  step; install_packages
  step; configure
  step; fetch_package
  step; ensure_user_and_dirs; install_release
  step; ensure_database; write_env
  step; activate; prune_releases
  step
  if [[ -n $HTTPS_HOST ]] || ask_yn "Set up HTTPS with a trusted certificate now? (needs a domain on Cloudflare)" n; then
    https_setup || true
  else
    info "Skipped. You can add it later with: sudo meshcore-home https"
  fi
  step; security_updates_setup || true
  finish
}

main
