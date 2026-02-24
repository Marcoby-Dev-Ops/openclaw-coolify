# Nexus Control Plane: Authority & Governance

This document defines the formal authority gradients and operational boundaries for the **Marcoby AI OS**. These rules are enforced at the bootstrap, orchestration, and proxy layers.

## 🏛️ Authority Gradients

### Tier 1: Executive Brain (Main / Chief of Staff)
**Role**: Strategic Orchestration & Decision Making.
- **Authority**: Propose initiatives, analyze project health, delegate tasks to sub-agents.
- **Tools**: Restricted (No `exec`, No `sandbox` creation/management).
- **Constraint**: Must follow the "Authority Awareness" protocol before requesting infrastructure resources.

### Tier 2: Business Integration (Nexus Agent)
**Role**: Real-world Bridge (Email, Calendar, CRM).
- **Authority**: Read/Write business state via specialized Nexus tools.
- **Tools**: `nexus_*`, `browser`, `web_search`.
- **Constraint**: No infrastructure authority. No `exec`, no `sandbox` management.

### Tier 3: Sandbox Runtime (Worker Agents)
**Role**: Tactical Execution & Implementation.
- **Authority**: Build and run code, manage project dependencies, execute tests.
- **Tools**: `exec`, `process`, `read`, `write`, `edit`, `apply_patch`, `image`.
- **Constraint**: No business knowledge. No access to `nexus_*` tools. Image-First philosophy (No `docker build` / `docker push`).

---

## 🔐 System Constraints (The Prime Directives)

### 1. The Socket Rule
All Docker operations MUST go through the `docker-socket-proxy`. The `DOCKER_HOST` is locked to `tcp://docker-proxy:2375`. Bypassing the proxy via `unix:///var/run/docker.sock` is a terminal violation.

### 2. The No-Build Guarantee
This system is an **Orchestrator**, not a builder.
- `docker build` and `docker push` are permanently forbidden.
- Agents MUST utilize the **Image-First Philosophy**: Select and run trusted, existing images for all layers.

### 3. Economic Governance
- **Max Sandboxes**: 10 concurrent containers.
- **Concurrent Agents**: 4 active agents.
- **Expiry**: All sandboxes are ephemeral and must include an expiration timestamp in `sandboxes.json`.

---

*Governance v0.8. Established for the Nexus Control Plane.*
