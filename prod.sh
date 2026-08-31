#!/usr/bin/env bash
# prod.sh - build the site, run Caddy in Docker, get SSL automatically.
# Nothing is installed on the host; everything runs in the official Caddy image.
#
#   ./prod.sh            build + start in the background (default)
#   ./prod.sh up         same, but stay attached to the logs
#   ./prod.sh stop       stop the container
#   ./prod.sh restart    rebuild the site and reload Caddy
#   ./prod.sh build      only regenerate site/ and Caddyfile
#   ./prod.sh logs       follow the request log (JSON, one line per request)
#   ./prod.sh console    follow Caddy's readable console output
#   ./prod.sh status     container state + certificate info
#
# On the first run it asks for the enamad code and the domain, and saves both to
# config.env. To skip the prompts, fill config.env in, or pass them as env vars:
#   DOMAIN=mysite.ir ENAMAD_CODE=12345678 ./prod.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SITE_DIR="$ROOT/site"
LOG_DIR="$ROOT/logs"
CADDYFILE="$ROOT/Caddyfile"
CONFIG="$ROOT/config.env"
ACCESS_LOG="$LOG_DIR/access.log"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

DOCKER=(docker)          # may become (sudo docker)
DC=()                    # built by ensure_docker

# ---------------------------------------------------------------- config ----
load_config() {
  [ -f "$CONFIG" ] || die "config.env not found next to prod.sh"
  # env vars that are already set win over the file
  # remember env vars set by the caller: they win over the file
  local _d="${DOMAIN-}" _c="${ENAMAD_CODE-}" _w="${WITH_WWW-}" _e="${ACME_EMAIL-}"
  local _hp="${HTTP_PORT-}" _sp="${HTTPS_PORT-}" _img="${CADDY_IMAGE-}"
  # shellcheck disable=SC1090
  set -a; . "$CONFIG"; set +a
  [ -n "$_d" ]   && DOMAIN="$_d"
  [ -n "$_c" ]   && ENAMAD_CODE="$_c"
  [ -n "$_w" ]   && WITH_WWW="$_w"
  [ -n "$_e" ]   && ACME_EMAIL="$_e"
  [ -n "$_hp" ]  && HTTP_PORT="$_hp"
  [ -n "$_sp" ]  && HTTPS_PORT="$_sp"
  [ -n "$_img" ] && CADDY_IMAGE="$_img"
  : "${WITH_WWW:=1}" "${ACME_EMAIL:=}" "${HTTP_PORT:=80}" "${HTTPS_PORT:=443}"
  : "${CADDY_IMAGE:=caddy:2-alpine}"
  export DOMAIN ENAMAD_CODE HTTP_PORT HTTPS_PORT CADDY_IMAGE
}

# rewrite (or append) KEY=value in config.env, keeping comments intact
set_config_value() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)" || die "could not create a temp file"
  awk -v k="$key" -v v="$val" '
    $0 ~ "^[[:space:]]*"k"=" && !done { print k"="v; done=1; next }
    { print }
    END { if (!done) print k"="v }
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

interactive() { [ -t 0 ] && [ -t 1 ]; }

# a domain may be pasted as https://www.site.ir/ - take just the host
clean_domain() {
  local d="$1"
  d="${d#*://}"      # drop scheme
  d="${d%%/*}"       # drop path
  d="${d%%:*}"       # drop port
  printf '%s' "$d" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# ask for anything still missing, then remember it in config.env
prompt_config() {
  local ans saved=0

  while [ -z "${ENAMAD_CODE:-}" ] || ! [[ "$ENAMAD_CODE" =~ ^[0-9]+$ ]]; do
    [ -n "${ENAMAD_CODE:-}" ] && warn "the code must be digits only (got: $ENAMAD_CODE)"
    interactive || die "ENAMAD_CODE is not set. Put it in config.env, or run:
        ENAMAD_CODE=60511192 ./prod.sh"
    printf '\033[1;36m==>\033[0m enamad code (the number from enamad.ir): '
    read -r ans || die "no input"
    ENAMAD_CODE="$(printf '%s' "$ans" | tr -d '[:space:]')"
    saved=1
  done

  # a real domain has a dot; "localhost" is allowed for local testing
  while [ -z "${DOMAIN:-}" ] || { [[ "$DOMAIN" != *.* ]] && [ "$DOMAIN" != "localhost" ]; }; do
    [ -n "${DOMAIN:-}" ] && warn "that does not look like a domain (got: $DOMAIN)"
    interactive || die "DOMAIN is not set. Put it in config.env, or run:
        DOMAIN=mysite.ir ./prod.sh"
    printf '\033[1;36m==>\033[0m domain to serve it on (e.g. mysite.ir): '
    read -r ans || die "no input"
    DOMAIN="$(clean_domain "$ans")"
    # "www.mysite.ir" means the bare domain plus www
    if [ "${DOMAIN#www.}" != "$DOMAIN" ]; then
      DOMAIN="${DOMAIN#www.}"
      WITH_WWW=1
    fi
    saved=1
  done

  if [ "$saved" = "1" ]; then
    set_config_value ENAMAD_CODE "$ENAMAD_CODE"
    set_config_value DOMAIN "$DOMAIN"
    set_config_value WITH_WWW "$WITH_WWW"
    say "saved to config.env - it will not ask again"
  fi
  export DOMAIN ENAMAD_CODE
}

# last line of defence for the non-interactive paths
validate_config() {
  [ -n "${DOMAIN:-}" ] || die "set DOMAIN in config.env"
  [ -n "${ENAMAD_CODE:-}" ] || die "set ENAMAD_CODE in config.env"
  [[ "$ENAMAD_CODE" =~ ^[0-9]+$ ]] \
    || die "ENAMAD_CODE must be digits only (got: $ENAMAD_CODE)"
}

OS="$(uname -s)"

confirm() {
  local reply
  if ! interactive; then
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    return 1
  fi
  printf '\033[1;36m==>\033[0m %s [y/N] ' "$1"
  read -r reply || return 1
  [[ "$reply" =~ ^[Yy] ]]
}

as_root() {
  if [ "$(id -u)" = "0" ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "need root for: $* (install sudo, or run this script as root)"
  fi
}

# ------------------------------------------------------- docker: install ----
install_docker_linux() {
  say "Docker is not installed."
  confirm "Install Docker Engine now (via https://get.docker.com)?" \
    || die "Docker is required. Install it, then re-run ./prod.sh
        docs: https://docs.docker.com/engine/install/"

  local script
  script="$(mktemp)"
  if curl -fsSL https://get.docker.com -o "$script" \
     || wget -qO "$script" https://get.docker.com; then
    say "running the official Docker install script"
    as_root sh "$script" || die "the Docker install script failed"
    rm -f "$script"
  else
    rm -f "$script"
    # distros the convenience script does not cover
    if command -v pacman >/dev/null 2>&1; then
      as_root pacman -Sy --noconfirm docker docker-compose
    elif command -v apk >/dev/null 2>&1; then
      as_root apk add --no-cache docker docker-cli-compose
    else
      die "could not download the installer. Install Docker manually:
        https://docs.docker.com/engine/install/"
    fi
  fi
  command -v docker >/dev/null 2>&1 || die "Docker still not on PATH after install"
  say "Docker installed"
}

install_docker_macos() {
  die "Docker is not installed.

  On macOS, install Docker Desktop yourself - this script will not do it for you:

      brew install --cask docker

  or download it from https://www.docker.com/products/docker-desktop/
  Then open Docker.app once and re-run ./prod.sh"
}

# --------------------------------------------------------- docker: daemon ----
start_docker_daemon() {
  local err tries=60
  err="$(mktemp)"

  if [ "$OS" = "Darwin" ]; then
    say "the Docker daemon is not running - starting Docker Desktop"
    # Docker Desktop takes a while to boot, so keep the full wait
    open -a Docker >"$err" 2>&1 || warn "could not launch Docker Desktop"
  else
    say "the Docker daemon is not running - starting it"
    if command -v systemctl >/dev/null 2>&1; then
      # --now also enables it at boot, so the site survives a reboot
      as_root systemctl enable --now docker >"$err" 2>&1 \
        || as_root systemctl start docker >"$err" 2>&1 \
        || tries=5
    elif command -v rc-service >/dev/null 2>&1; then
      as_root rc-service docker start >"$err" 2>&1 || tries=5
      as_root rc-update add docker default >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
      as_root service docker start >"$err" 2>&1 || tries=5
    else
      echo "no init system found (systemctl/rc-service/service)" >"$err"
      tries=5
    fi
    # the start command already failed - don't make the user wait two minutes
    [ "$tries" = "5" ] && warn "could not start the docker service:
$(sed 's/^/        /' "$err" | head -5)"
  fi

  local i
  for i in $(seq 1 "$tries"); do
    docker info >/dev/null 2>&1 && { rm -f "$err"; say "Docker is ready"; return 0; }
    sudo -n docker info >/dev/null 2>&1 && { rm -f "$err"; return 0; }
    sleep 2
  done
  rm -f "$err"
  die "the Docker daemon did not come up. Start it yourself and re-run ./prod.sh:
        sudo systemctl start docker"
}

# ------------------------------------------------- docker: compose plugin ----
install_compose_plugin() {
  say "the Docker Compose plugin is missing - installing it"
  if command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update -qq && as_root apt-get install -y docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y docker-compose-plugin
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -Sy --noconfirm docker-compose
  elif command -v apk >/dev/null 2>&1; then
    as_root apk add --no-cache docker-cli-compose
  fi
}

# Everything above, in order, so `docker compose` is usable when we return.
ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    case "$OS" in
      Darwin) install_docker_macos ;;
      Linux)  install_docker_linux ;;
      *)      die "unsupported platform: $OS - install Docker manually" ;;
    esac
  fi

  # can we talk to the daemon at all?
  if ! docker info >/dev/null 2>&1; then
    # a running daemon we simply lack permission for: use sudo and say so
    if sudo -n docker info >/dev/null 2>&1; then
      DOCKER=(sudo docker)
      warn "your user cannot reach the Docker socket, using sudo."
      warn "to fix it permanently: sudo usermod -aG docker ${USER:-$(id -un)}   (then log out and back in)"
    else
      start_docker_daemon
      if ! docker info >/dev/null 2>&1; then
        if sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
          DOCKER=(sudo docker)
          warn "using sudo for Docker. To fix: sudo usermod -aG docker ${USER:-$(id -un)}"
        else
          die "cannot talk to the Docker daemon"
        fi
      fi
    fi
  fi

  if ! "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    [ "$OS" = "Linux" ] && install_compose_plugin
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 \
    || die "'docker compose' is unavailable. Install the Compose plugin:
        https://docs.docker.com/compose/install/"

  DC=("${DOCKER[@]}" compose --env-file "$CONFIG")
}

# ----------------------------------------------------------------- build ----
build() {
  mkdir -p "$SITE_DIR" "$LOG_DIR"

  say "rendering site for code $ENAMAD_CODE"
  sed -e "s/__CODE__/${ENAMAD_CODE}/g" -e "s/__DOMAIN__/${DOMAIN}/g" \
    "$ROOT/template.html" > "$SITE_DIR/index.html"

  # enamad verification file: https://<domain>/<code>.txt  (clear stale ones)
  find "$SITE_DIR" -maxdepth 1 -name '*.txt' -delete
  printf '%s\n' "$ENAMAD_CODE" > "$SITE_DIR/${ENAMAD_CODE}.txt"

  local hosts="$DOMAIN"
  [ "$WITH_WWW" = "1" ] && hosts="$DOMAIN, www.$DOMAIN"

  local email_line=""
  [ -n "$ACME_EMAIL" ] && email_line=$'\n\temail '"$ACME_EMAIL"

  say "writing Caddyfile for $hosts"
  cat > "$CADDYFILE" <<EOF
# Generated by prod.sh - edit config.env, not this file.
{
	admin off${email_line}
}

${hosts} {
	root * /srv
	encode zstd gzip
	file_server

	# the enamad verification file must be served as plain text
	header /*.txt Content-Type "text/plain; charset=utf-8"

	# every incoming request, one JSON object per line, on the host in ./logs
	log requests {
		output file /var/log/caddy/access.log {
			roll_size 10MiB
			roll_keep 10
			roll_keep_for 720h
		}
		format json
	}

	# ...and the same, human-readable, on the container's console
	log console {
		output stderr
		format console
	}
}
EOF

  say "validating Caddyfile"
  "${DOCKER[@]}" run --rm -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "Caddyfile failed validation"

  say "built site/index.html and site/${ENAMAD_CODE}.txt"
}

# ------------------------------------------------------------- preflight ----
preflight() {
  local pub res
  pub="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  res="$("${DOCKER[@]}" run --rm --entrypoint sh "$CADDY_IMAGE" \
          -c "nslookup $DOMAIN 2>/dev/null | awk '/^Address/{a=\$NF} END{print a}'" 2>/dev/null || true)"
  if [ -n "$pub" ] && [ -n "$res" ] && [ "$pub" != "$res" ]; then
    warn "$DOMAIN resolves to $res but this machine's public IP is $pub."
    warn "Let's Encrypt will not issue a certificate until DNS points here."
  fi
  # lsof is on macOS by default, ss/netstat on most Linux servers
  local p listening
  for p in "$HTTP_PORT" "$HTTPS_PORT"; do
    listening=""
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && listening=1
    elif command -v ss >/dev/null 2>&1; then
      ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN && listening=1
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]" && listening=1
    fi
    if [ -n "$listening" ]; then
      warn "port $p is already in use - Caddy may fail to bind it"
    fi
  done
  return 0
}

# ------------------------------------------------------------------- run ----
up() {
  local attached="$1"
  preflight
  say "pulling $CADDY_IMAGE"
  "${DC[@]}" pull -q caddy || true
  say "starting Caddy - SSL is requested automatically on first boot"
  if [ "$attached" = "1" ]; then
    exec "${DC[@]}" up
  fi
  "${DC[@]}" up -d
  sleep 3
  "${DC[@]}" ps
  echo
  say "https://${DOMAIN}"
  say "https://${DOMAIN}/${ENAMAD_CODE}.txt"
  say "requests: ./prod.sh logs   |   stop: ./prod.sh stop"
}

status() {
  "${DC[@]}" ps
  echo
  say "certificates in the caddy_data volume:"
  local vol
  vol="$("${DC[@]}" config --volumes >/dev/null 2>&1; "${DOCKER[@]}" volume ls -q \
        | grep -E '_caddy_data$' | head -1)"
  if [ -n "$vol" ]; then
    "${DOCKER[@]}" run --rm -v "$vol:/data" --entrypoint sh "$CADDY_IMAGE" \
      -c "find /data/caddy/certificates -name '*.crt' 2>/dev/null" \
      | sed 's|^|  |' || true
  else
    echo "  (no volume yet - start the server first)"
  fi
}

# ------------------------------------------------------------------ main ----
case "${1:-start}" in
  start|"")  ensure_docker; load_config; prompt_config; validate_config; build; up 0 ;;
  up)        ensure_docker; load_config; prompt_config; validate_config; build; up 1 ;;
  build)     ensure_docker; load_config; prompt_config; validate_config; build ;;
  restart)   ensure_docker; load_config; prompt_config; validate_config; build
             "${DC[@]}" restart; say "reloaded" ;;
  stop|down) ensure_docker; load_config; "${DC[@]}" down; say "stopped" ;;
  logs)      [ -f "$ACCESS_LOG" ] || die "no requests logged yet ($ACCESS_LOG)"
             tail -f "$ACCESS_LOG" ;;
  console)   ensure_docker; load_config; "${DC[@]}" logs -f ;;
  status)    ensure_docker; load_config; status ;;
  *) die "unknown command: $1 (use: start | up | build | restart | stop | logs | console | status)" ;;
esac
