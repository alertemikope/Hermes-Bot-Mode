#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:?profile required}"
SLOT="${2:?slot required}"
DISPLAY_NUMBER=$((10 + SLOT))
VNC_PORT=$((5900 + SLOT))
WEB_PORT=$((6080 + SLOT))
export DISPLAY=":${DISPLAY_NUMBER}"
export HOME="${BOX_DATA:-/data}/profiles/${PROFILE}"
export XDG_RUNTIME_DIR="/tmp/forever-box-${PROFILE}"
SOCKET="${BOX_SOCKET_DIR:-/run/hermes-box}/${PROFILE}.sock"
LOG_DIR="/var/log/forever-box/${PROFILE}"
SESSION_UID="${BOX_SESSION_UID:-1000}"
SESSION_GID="${BOX_SESSION_GID:-1000}"
PIDS=()

mkdir -p "$HOME/chromium" "$HOME/.config/fluxbox" "$XDG_RUNTIME_DIR" "$LOG_DIR" /tmp/.X11-unix
if [[ "$(id -u)" == "0" && "${BOX_SESSION_DROPPED:-0}" != "1" ]]; then
  chown -R "$SESSION_UID:$SESSION_GID" "$HOME" "$XDG_RUNTIME_DIR" "$LOG_DIR"
  chmod 0777 "${BOX_SOCKET_DIR:-/run/hermes-box}"
  exec env BOX_SESSION_DROPPED=1 setpriv \
    --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups \
    "$0" "$@"
fi
chmod 0700 "$XDG_RUNTIME_DIR"
rm -f "/tmp/.X${DISPLAY_NUMBER}-lock" "/tmp/.X11-unix/X${DISPLAY_NUMBER}" "$SOCKET"

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM

Xvfb "$DISPLAY" -screen 0 1440x900x24 -ac +extension RANDR +extension XTEST +render -noreset >"$LOG_DIR/xvfb.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 100); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.1
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1

eval "$(dbus-launch --sh-syntax)"
xsetroot -solid '#111113' >/dev/null 2>&1 || true
fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
PIDS+=("$!")

chromium \
  --no-sandbox --disable-dev-shm-usage --disable-gpu --no-first-run \
  --no-default-browser-check --disable-session-crashed-bubble \
  --password-store=basic --user-data-dir="$HOME/chromium" --start-maximized \
  about:blank >"$LOG_DIR/chromium.log" 2>&1 &
PIDS+=("$!")

x11vnc -display "$DISPLAY" -forever -shared -nopw -listen 127.0.0.1 \
  -rfbport "$VNC_PORT" -xkb -ncache 0 >"$LOG_DIR/x11vnc.log" 2>&1 &
PIDS+=("$!")
websockify --web=/usr/share/novnc "0.0.0.0:${WEB_PORT}" "127.0.0.1:${VNC_PORT}" >"$LOG_DIR/novnc.log" 2>&1 &
PIDS+=("$!")

CUA_DRIVER_RS_TELEMETRY_ENABLED=0 cua-driver serve --socket "$SOCKET" \
  --permission-mode standard >"$LOG_DIR/cua-driver.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 100); do
  if [[ -S "$SOCKET" ]]; then chmod 0666 "$SOCKET"; break; fi
  sleep 0.1
done
[[ -S "$SOCKET" ]]

wait "${PIDS[0]}"
