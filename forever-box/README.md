# Hermes Forever Box

This deployment adds Grok-style computer use to Hermes Bot Mode without a cloud VM provider. One persistent Linux container owns the computer, while every Hermes profile receives a stable private X display, Chromium profile, noVNC endpoint, and Cua Driver socket.

## Topology

- `forever-box`: shared filesystem and process boundary, one display per profile.
- `gateway`: Hermes messaging gateways with `computer_use` routed by `HERMES_HOME`.
- `dashboard`: the remote backend used by Hermes Desktop.
- noVNC and the broker bind only to the configured Tailscale address.

Assignments persist in the `box-data` volume. Browser state lives at `/data/profiles/<profile>/chromium`. The broker is bearer-token protected; no Cua socket or VNC server is exposed outside the Docker network/Tailscale binding.

## Deploy

```bash
cp .env.example .env
openssl rand -hex 32  # use as BOX_BROKER_TOKEN
git clone https://github.com/NousResearch/hermes-agent ../hermes-agent
./deploy.sh
```

Add dashboard credentials to `data/.env` before exposing the backend:

```dotenv
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=<scrypt hash>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<stable random secret>
```

In Hermes Desktop, select **Remote gateway** and use `http://<tailscale-ip>:9119`. In the Computer pane, save `http://<tailscale-ip>:8787` and the broker token.
