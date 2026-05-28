OpenClaw operations helpers
===========================

This document explains two helper scripts added to `scripts/`:

- `apply_openclaw_config.sh` — atomically validate and apply an `openclaw.json` file, backup the previous config, and probe the runtime.
- `probe_auth_profiles.sh` — scans `auth-profiles.json` files for expiring tokens and optionally posts a simple alert to a webhook.

Examples
--------

Apply a new config file (atomic):

```bash
# From host or inside a maintainer container that can write /data/.openclaw
./scripts/apply_openclaw_config.sh /path/to/new_openclaw.json
```

Probe auth profiles (cron):

```bash
# run daily via cron and set OPENCLAW_ALERT_WEBHOOK to a simple incoming webhook URL
OPENCLAW_ALERT_WEBHOOK=https://hooks.example.com/xx ./scripts/probe_auth_profiles.sh
```

Cron example (run probe every day at 02:30):

```cron
30 2 * * * cd /srv/openclaw && OPENCLAW_ALERT_WEBHOOK=https://hooks.example.com/xx ./scripts/probe_auth_profiles.sh >> /var/log/openclaw/probe.log 2>&1
```

Notes & recommendations
-----------------------
- Use `apply_openclaw_config.sh` from a trusted operator environment; it will back up the existing config to `/data/.openclaw/backups` before replacing.
- The probe script performs heuristic detection of expiry fields—adjust `WARNING_DAYS` env var as needed.
- Consider wiring `probe_auth_profiles.sh` into your monitoring/alerting for automated ticketing or Slack notifications.
