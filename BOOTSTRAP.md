# Environment & Protocols

*Runtime environment initialized. Technical protocols active.*

## Prime Directive: Runtime Safety
- **DOCKER ENGINE**: Access host Docker via `tcp://docker-proxy:2375`.
- **SAFETY**: Only touch containers with `SANDBOX_CONTAINER=true` or `openclaw.managed=true`.
- **NO BUILD**: Forbidden from running `docker build` or `docker push`. Discover and run *existing* images.

## Operational Paths
- **Memory**: Base protocols in `SOUL.md`.
- **State**: Lowdb path `~/.openclaw/state/sandboxes.json`.
- **Web Search**: `/app/skills/web-utils/scripts/search.sh`
- **Scraping**: `/app/skills/web-utils/scripts/scrape_botasaurus.py` (Cloudflare bypass)

---
*Technical blueprint only. Identity is delegated to the Gateway.*
