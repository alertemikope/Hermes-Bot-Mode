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
export NO_AT_BRIDGE=0
SOCKET="${BOX_SOCKET_DIR:-/run/hermes-box}/${PROFILE}.sock"
LOG_DIR="/var/log/forever-box/${PROFILE}"
SESSION_UID="${BOX_SESSION_UID:-1000}"
SESSION_GID="${BOX_SESSION_GID:-1000}"
PIDS=()

mkdir -p "$HOME/chromium" "$HOME/.config/fluxbox" "$XDG_RUNTIME_DIR" "$LOG_DIR" /tmp/.X11-unix
if [[ "$(id -u)" == "0" && "${BOX_SESSION_DROPPED:-0}" != "1" ]]; then
  # dbus-daemon refuses to start for a numeric uid that NSS cannot resolve.
  # Keep non-default BOX_SESSION_UID/GID overrides working as well as the
  # image's built-in uid 1000 entry. Multiple restored profiles may race here,
  # so serialize the small local NSS update.
  (
    flock 9
    if ! getent group "$SESSION_GID" >/dev/null; then
      printf 'hermes-box-%s:x:%s:\n' "$SESSION_GID" "$SESSION_GID" >> /etc/group
    fi
    if ! getent passwd "$SESSION_UID" >/dev/null; then
      printf 'hermes-box-%s:x:%s:%s:Hermes Forever Box:%s:/usr/sbin/nologin\n' \
        "$SESSION_UID" "$SESSION_UID" "$SESSION_GID" "$HOME" >> /etc/passwd
    fi
  ) 9>/tmp/hermes-box-nss.lock
  chown -R "$SESSION_UID:$SESSION_GID" "$HOME" "$XDG_RUNTIME_DIR" "$LOG_DIR"
  chmod 0777 "${BOX_SOCKET_DIR:-/run/hermes-box}"
  exec env BOX_SESSION_DROPPED=1 setpriv \
    --reuid="$SESSION_UID" --regid="$SESSION_GID" --clear-groups \
    "$0" "$@"
fi
chmod 0700 "$XDG_RUNTIME_DIR"
rm -f "/tmp/.X${DISPLAY_NUMBER}-lock" "/tmp/.X11-unix/X${DISPLAY_NUMBER}" "$SOCKET"
# Chromium stores these process-singleton artifacts in the persistent profile.
# They are valid only for the container instance that created them and would
# otherwise block the browser after a normal container recreation.
rm -f "$HOME/chromium/SingletonLock" "$HOME/chromium/SingletonSocket" "$HOME/chromium/SingletonCookie"

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM

Xvfb "$DISPLAY" -screen 0 1440x900x24 -ac +extension RANDR +extension XTEST +render -noreset >"$LOG_DIR/xvfb.log" 2>&1 &
XVFB_PID="$!"
PIDS+=("$XVFB_PID")
for _ in $(seq 1 100); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.1
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1

dbus_env="$(dbus-launch --sh-syntax 2>>"$LOG_DIR/dbus.log")"
eval "$dbus_env"
export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID

# Force activation of the per-session AT-SPI registry before Chromium and the
# CUA daemon start. This makes semantic inspection deterministic instead of
# relying on the first accessibility query to win a startup race.
for _ in $(seq 1 50); do
  if dbus-send --session --print-reply --dest=org.a11y.Bus \
      /org/a11y/bus org.a11y.Bus.GetAddress >>"$LOG_DIR/at-spi.log" 2>&1; then
    break
  fi
  sleep 0.1
done
dbus-send --session --print-reply --dest=org.a11y.Bus \
  /org/a11y/bus org.a11y.Bus.GetAddress >>"$LOG_DIR/at-spi.log" 2>&1

xsetroot -solid '#111113' >/dev/null 2>&1 || true
fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
PIDS+=("$!")

chromium \
  --no-sandbox --disable-dev-shm-usage --disable-gpu --no-first-run \
  --force-renderer-accessibility \
  --no-default-browser-check --disable-session-crashed-bubble \
  --password-store=basic --user-data-dir="$HOME/chromium" --start-maximized \
  about:blank >"$LOG_DIR/chromium.log" 2>&1 &
CHROMIUM_PID="$!"
PIDS+=("$CHROMIUM_PID")

x11vnc -display "$DISPLAY" -forever -shared -nopw -listen 127.0.0.1 \
  -rfbport "$VNC_PORT" -xkb -ncache 0 >"$LOG_DIR/x11vnc.log" 2>&1 &
PIDS+=("$!")
websockify --web=/usr/share/novnc "0.0.0.0:${WEB_PORT}" "127.0.0.1:${VNC_PORT}" >"$LOG_DIR/novnc.log" 2>&1 &
PIDS+=("$!")

CUA_DRIVER_RS_TELEMETRY_ENABLED=0 cua-driver serve --socket "$SOCKET" \
  --permission-mode standard >"$LOG_DIR/cua-driver.log" 2>&1 &
CUA_PID="$!"
PIDS+=("$CUA_PID")
for _ in $(seq 1 100); do
  if [[ -S "$SOCKET" ]]; then chmod 0666 "$SOCKET"; break; fi
  sleep 0.1
done
[[ -S "$SOCKET" ]]
kill -0 "$CHROMIUM_PID"

# These three processes define a usable session. If any exits, tear down the
# rest so the broker observes the failure and can rebuild a coherent desktop.
wait -n "$XVFB_PID" "$CHROMIUM_PID" "$CUA_PID"
