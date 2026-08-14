FROM debian:bookworm-slim

ARG CUA_DRIVER_VERSION=0.19.3
ARG CUA_DRIVER_URL=https://files.pythonhosted.org/packages/88/26/1b372765b192a2f4f7ee7e1474d1e39be9ab3bd637765f632e30e7ee6e18/cua_driver-0.19.3-py3-none-manylinux_2_31_x86_64.whl
ARG CUA_DRIVER_SHA256=3f327a444f5b666037dee5e7c15c98990abbfb4fe83669ef708cb34c2cafef14

RUN apt-get update && apt-get install -y --no-install-recommends \
      at-spi2-core bash ca-certificates chromium curl dbus-x11 fluxbox fonts-dejavu-core \
      fonts-liberation novnc procps python3 python3-venv util-linux websockify x11-utils \
      x11-xserver-utils x11vnc xdotool xterm xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && wheel="/tmp/cua_driver-${CUA_DRIVER_VERSION}-py3-none-manylinux_2_31_x86_64.whl" \
    && curl -fsSL "$CUA_DRIVER_URL" -o "$wheel" \
    && echo "$CUA_DRIVER_SHA256  $wheel" | sha256sum -c - \
    && python3 -m venv /opt/cua \
    && /opt/cua/bin/pip install --no-cache-dir --no-deps "$wheel" \
    && driver_bin="$(find /opt/cua/lib -path '*/cua_driver/bin/cua-driver' -type f -print -quit)" \
    && test -n "$driver_bin" \
    && install -m 0755 "$driver_bin" /usr/local/bin/cua-driver \
    && test "$(cua-driver --version)" = "cua-driver ${CUA_DRIVER_VERSION}" \
    && rm -f "$wheel" \
    && mkdir -p /data/profiles /run/hermes-box /var/log/forever-box \
    && { getent group 1000 >/dev/null || printf 'hermes:x:1000:\n' >> /etc/group; } \
    && { getent passwd 1000 >/dev/null || printf 'hermes:x:1000:1000:Hermes Forever Box:/data:/usr/sbin/nologin\n' >> /etc/passwd; }

COPY broker.py /usr/local/lib/forever-box/broker.py
COPY start-session.sh /usr/local/bin/start-forever-box-session
RUN chmod 0755 /usr/local/bin/start-forever-box-session

ENV BOX_DATA=/data
ENV BOX_SOCKET_DIR=/run/hermes-box
ENV BOX_MAX_SESSIONS=12
ENV BOX_PUBLIC_HOST=127.0.0.1
ENV PYTHONUNBUFFERED=1

VOLUME ["/data", "/run/hermes-box"]
EXPOSE 8787 6080-6091
ENTRYPOINT ["python3", "/usr/local/lib/forever-box/broker.py"]
