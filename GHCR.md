Using GHCR image instead of building
==================================

If you want Coolify to pull the OpenClaw image from GitHub Container Registry (GHCR) instead of building on each redeploy, set the `OPENCLAW_IMAGE` environment variable to the image you want and deploy using `docker-compose.ghcr.yaml`.

Example
-------

1. Set Coolify env var (optional): `OPENCLAW_IMAGE=ghcr.io/marcoby-dev-ops/openclaw-coolify:latest`
2. In Coolify, create the app using the repository and point the **Docker Compose file** to `docker-compose.ghcr.yaml`.
3. Redeploy — Coolify will pull the image instead of building the container on the host.

Notes
-----
- The provided `docker-compose.ghcr.yaml` mirrors the service config but uses an image reference for `openclaw` (defaults to `:latest`).
- You can override the default tag by setting `OPENCLAW_IMAGE` to a specific GHCR tag or digest (recommended for production).
- If you need both options (build from source for dev, pull image for production), keep both compose files and choose the appropriate one when creating/updating the Coolify app.
