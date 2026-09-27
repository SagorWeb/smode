#!/bin/sh
set -eu

RAW="${SMODE_URL:-https://raw.githubusercontent.com/SagorWeb/smode/main}"
PORT="${PORT:-8787}"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
machine=$(uname -m)
case "$machine" in
  x86_64|amd64) arch="x64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "This machine type is not supported: $machine" >&2; exit 1 ;;
esac
case "$os" in
  linux) ;;
  *) echo "This installer supports Linux. Detected: $os" >&2; exit 1 ;;
esac
target="${os}-${arch}"

if [ "$(id -u)" -eq 0 ]; then
  PREFIX="${PREFIX:-/opt/smode}"
  DATA="${DATA_DIR:-/var/lib/smode}"
  HOST="${HOST:-0.0.0.0}"
else
  PREFIX="${PREFIX:-$HOME/.smode}"
  DATA="${DATA_DIR:-$HOME/.smode/data}"
  HOST="${HOST:-127.0.0.1}"
fi

if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl cat smode >/dev/null 2>&1; then
  systemctl stop smode >/dev/null 2>&1 || true
fi
if [ "$(id -u)" -eq 0 ] && command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl stop smode >/dev/null 2>&1 || true
fi
if [ -f "${PREFIX:-/opt/smode}/smode.pid" ]; then
  old=$(cat "${PREFIX:-/opt/smode}/smode.pid" 2>/dev/null || true)
  if [ -n "${old:-}" ]; then
    kill "$old" 2>/dev/null || true
  fi
fi
sleep 1

if command -v ss >/dev/null 2>&1; then
  if ss -lnt | grep -E -q ":${PORT}([^0-9]|$)"; then
    echo "Port ${PORT} is already in use. Run again with PORT= set to a free port." >&2
    exit 1
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

script_path=$0
case "$script_path" in
  */*) script_dir=$(CDPATH= cd -- "$(dirname "$script_path")" && pwd) ;;
  *) script_dir="" ;;
esac

asset="smode-${target}"
if [ -n "$script_dir" ] && [ -f "$script_dir/$asset" ] && [ -f "$script_dir/SHA256SUMS" ]; then
  cp "$script_dir/$asset" "$tmp/$asset"
  cp "$script_dir/SHA256SUMS" "$tmp/SHA256SUMS"
else
  echo "Downloading ${asset}"
  curl -fsSL "$RAW/$asset" -o "$tmp/$asset"
  curl -fsSL "$RAW/SHA256SUMS" -o "$tmp/SHA256SUMS"
fi

expected=$(awk -v file="$asset" '$2 == file { print $1; exit }' "$tmp/SHA256SUMS")
if [ -z "$expected" ]; then
  echo "No checksum for ${asset}." >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
else
  echo "sha256sum is required to verify the download." >&2
  exit 1
fi
if [ "$actual" != "$expected" ]; then
  echo "Checksum mismatch for ${asset}." >&2
  exit 1
fi

mkdir -p "$PREFIX" "$DATA"
install -m 0755 "$tmp/$asset" "$PREFIX/smode"

VAST_BIND_PORT=""
VAST_PUBLIC_PORT=""
if [ -n "${PUBLIC_IPADDR:-}" ] && [ -f /etc/portal.yaml ]; then
  for item in $(env); do
    case "$item" in
      VAST_TCP_PORT_*)
        key=${item%%=*}
        val=${item#*=}
        port=${key#VAST_TCP_PORT_}
        case "$port" in
          ''|*[!0-9]*) continue ;;
        esac
        if [ "$port" -gt 65535 ]; then
          continue
        fi
        case "$port" in
          22|1111|8080|8384|6006) continue ;;
        esac
        if grep -q "external_port: ${port}" /etc/portal.yaml; then
          continue
        fi
        VAST_BIND_PORT=$port
        VAST_PUBLIC_PORT=$val
        break
        ;;
    esac
  done
fi

if [ -n "$VAST_BIND_PORT" ]; then
  HOST="127.0.0.1"
  public="http://${PUBLIC_IPADDR}:${VAST_PUBLIC_PORT}"
else
  addr="$HOST"
  if [ "$HOST" = "0.0.0.0" ] || [ "$HOST" = "::" ]; then
    addr=$(hostname -I 2>/dev/null | awk '{ print $1 }')
    if [ -z "$addr" ]; then
      addr="127.0.0.1"
    fi
  fi
  public="http://${addr}:${PORT}"
fi

cat > "$PREFIX/smode.env" << EOF
export HOST=${HOST}
export PORT=${PORT}
export LAB_ROOT=${PREFIX}
export DATA_DIR=${DATA}
export PUBLIC_URL=${public}/admin/
EOF
chmod 0644 "$PREFIX/smode.env"

started=0
if [ "$(id -u)" -eq 0 ] && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/smode.service << EOF
[Unit]
Description=smode
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
EnvironmentFile=${PREFIX}/smode.env
ExecStart=${PREFIX}/smode
Restart=on-failure
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=25

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable smode >/dev/null
  systemctl restart smode
  started=1
elif [ "$(id -u)" -eq 0 ] && command -v supervisorctl >/dev/null 2>&1 && [ -d /etc/supervisor/conf.d ]; then
  cat > /etc/supervisor/conf.d/smode.conf << EOF
[program:smode]
command=/bin/sh -c 'set -a; . ${PREFIX}/smode.env; set +a; exec ${PREFIX}/smode'
directory=${PREFIX}
autostart=true
autorestart=true
stopsignal=TERM
stopwaitsecs=25
stdout_logfile=/var/log/smode.log
stderr_logfile=/var/log/smode.err.log
EOF
  supervisorctl reread >/dev/null
  supervisorctl update >/dev/null
  supervisorctl restart smode >/dev/null
  started=1
else
  if [ -f "$PREFIX/smode.pid" ]; then
    old=$(cat "$PREFIX/smode.pid" 2>/dev/null || true)
    if [ -n "$old" ]; then
      kill "$old" 2>/dev/null || true
    fi
  fi
  # shellcheck disable=SC1090
  set -a
  . "$PREFIX/smode.env"
  set +a
  nohup "$PREFIX/smode" >> "$PREFIX/smode.log" 2>&1 &
  echo $! > "$PREFIX/smode.pid"
  started=1
fi

if [ "$started" -ne 1 ]; then
  echo "smode was installed but not started." >&2
  exit 1
fi

if [ -n "$VAST_BIND_PORT" ]; then
  python3 - "$VAST_BIND_PORT" "$PORT" << 'PY'
import sys
from pathlib import Path
import yaml
external = int(sys.argv[1])
internal = int(sys.argv[2])
path = Path("/etc/portal.yaml")
data = yaml.safe_load(path.read_text()) or {"applications": {}}
apps = data.setdefault("applications", {})
apps["smode"] = {
    "hostname": "127.0.0.1",
    "external_port": external,
    "internal_port": internal,
    "open_path": "/",
    "name": "smode",
}
path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
  envfile="${WORKSPACE:-/workspace}/.env"
  mkdir -p "$(dirname "$envfile")"
  touch "$envfile"
  if grep -q '^AUTH_EXCLUDE=' "$envfile"; then
    current=$(sed -n 's/^AUTH_EXCLUDE=//p' "$envfile" | head -n 1)
    case ",${current}," in
      *",${VAST_BIND_PORT},"*) ;;
      *)
        sed -i "s/^AUTH_EXCLUDE=.*/AUTH_EXCLUDE=${current},${VAST_BIND_PORT}/" "$envfile"
        ;;
    esac
  else
    printf 'AUTH_EXCLUDE=%s\n' "$VAST_BIND_PORT" >> "$envfile"
  fi
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl restart caddy >/dev/null
  fi
fi

ready=0
i=0
while [ "$i" -lt 30 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/docs/" || true)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "smode did not answer on port ${PORT}." >&2
  if [ -f /var/log/smode.log ]; then
    tail -n 40 /var/log/smode.log >&2 || true
  elif [ -f "$PREFIX/smode.log" ]; then
    tail -n 40 "$PREFIX/smode.log" >&2 || true
  fi
  exit 1
fi

key="$DATA/registry/bootstrap-access-key.txt"
i=0
while [ "$i" -lt 20 ] && [ ! -f "$key" ]; do
  i=$((i + 1))
  sleep 1
done
if [ ! -f "$key" ]; then
  echo "smode is running, but the access key was not written at ${key}." >&2
  exit 1
fi

echo "smode"
echo "${public}/"
echo "${public}/docs/"
echo "$key"
