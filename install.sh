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

addr="$HOST"
if [ "$HOST" = "0.0.0.0" ] || [ "$HOST" = "::" ]; then
  addr=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  if [ -z "$addr" ]; then
    addr="127.0.0.1"
  fi
fi
public="http://${addr}:${PORT}"

cat > "$PREFIX/smode.env" << EOF
HOST=${HOST}
PORT=${PORT}
LAB_ROOT=${PREFIX}
DATA_DIR=${DATA}
PUBLIC_URL=${public}/admin/
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
command=/bin/sh -c '. ${PREFIX}/smode.env && exec ${PREFIX}/smode'
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

key="$DATA/registry/bootstrap-access-key.txt"
i=0
while [ "$i" -lt 30 ] && [ ! -f "$key" ]; do
  i=$((i + 1))
  sleep 1
done

echo "smode"
echo "${public}/"
echo "${public}/docs/"
if [ -f "$key" ]; then
  echo "$key"
else
  echo "The access key file was not written yet. See ${DATA}/registry after the process finishes starting."
fi
