# syntax=docker/dockerfile:1
# Multi-stage build for optimal caching with BuildKit
# Each stage builds on the previous, with COPY . . only in the final stage
# BuildKit features: cache mounts, parallel builds, improved layer caching

# Stage 1: Base system dependencies (rarely changes)
FROM node:lts-bookworm-slim AS base

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_ROOT_USER_ACTION=ignore

# Install Core & Power Tools + Docker CLI (client only)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    build-essential \
    software-properties-common \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    lsof \
    openssl \
    ca-certificates \
    gnupg \
    ripgrep fd-find fzf bat \
    pandoc \
    poppler-utils \
    ffmpeg \
    imagemagick \
    graphviz \
    sqlite3 \
    pass \
    chromium \
    unzip \
    netcat-openbsd \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: System CLI tools (change occasionally)
FROM base AS system-tools

# Install Docker CE CLI, Go, Cloudflare Tunnel, and GitHub CLI
RUN apt-get update && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli gh && \
    npm install -g node-gyp && \
    ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then GO_ARCH="amd64"; else GO_ARCH="arm64"; fi && \
    curl -fsSL "https://go.dev/dl/go1.23.4.linux-${GO_ARCH}.tar.gz" | tar -C /usr/local -xzf - && \
    curl -fsSL -o cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" && \
    dpkg -i cloudflared.deb && \
    rm cloudflared.deb && \
    curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="/usr/local/bin" sh && \
    rm -rf /var/lib/apt/lists/*

# Stage 3: Language runtimes and package managers (change sometimes)
FROM system-tools AS runtimes

ENV BUN_INSTALL_NODE=0 \
    BUN_INSTALL="/data/.bun" \
    VIRTUAL_ENV="/opt/venv" \
    PATH="/opt/venv/bin:/usr/local/go/bin:/data/.bun/bin:/data/.bun/install/global/bin:$PATH"

# Setup Python Virtual Environment
RUN python3 -m venv $VIRTUAL_ENV

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash

# Python tools
RUN uv pip install ipython csvkit openpyxl python-docx pypdf botasaurus browser-use playwright && \
    apt-get update && playwright install-deps && rm -rf /var/lib/apt/lists/*

# Configure QMD Persistence
ENV XDG_CACHE_HOME="/data/.cache"

# Debian aliases
RUN ln -s /usr/bin/fdfind /usr/bin/fd || true && \
    ln -s /usr/bin/batcat /usr/bin/bat || true

# Stage 4: Application dependencies (package installations)
FROM runtimes AS dependencies

# OpenClaw install
ARG OPENCLAW_BETA=false
ARG OPENCLAW_VERSION=2026.4.14
ENV OPENCLAW_BETA=${OPENCLAW_BETA} \
    OPENCLAW_NO_ONBOARD=1 \
    NPM_CONFIG_UNSAFE_PERM=true \
    OPENCLAW_VERSION=${OPENCLAW_VERSION}

# Install Vercel, Marp, QMD with BuildKit cache mount for faster rebuilds
RUN --mount=type=cache,target=/data/.bun/install/cache \
    bun install -g vercel @marp-team/marp-cli https://github.com/tobi/qmd && hash -r && \
    bun pm -g untrusted && \
    bun install -g @openai/codex opencode-ai @steipete/summarize @hyperbrowser/agent clawhub

# Install pnpm, Gemini CLI, and OpenClaw.
# Gemini CLI must live under /usr/local, not /data/.bun, because /data is a
# runtime volume mount and would otherwise mask the binary after container boot.
RUN --mount=type=cache,target=/data/.npm \
    npm install -g pnpm @google/gemini-cli && \
    npm install -g openclaw@${OPENCLAW_VERSION} && \
    if command -v openclaw >/dev/null 2>&1; then \
    echo "✅ openclaw binary found"; \
    else \
    echo "❌ OpenClaw install failed (binary 'openclaw' not found)"; \
    exit 1; \
    fi


# AI Tool Suite & ClawHub
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    curl -fsSL https://code.kimi.com/install.sh | bash

# Stage 5: Final application stage (changes frequently)
FROM dependencies AS final

WORKDIR /app

# Copy everything (obeying .dockerignore)
# This is the only layer that changes on code updates
COPY . .

# Specialized symlinks and permissions
RUN ln -sf /data/.claude/bin/claude /usr/local/bin/claude 2>/dev/null || true && \
    ln -sf /data/.kimi/bin/kimi /usr/local/bin/kimi 2>/dev/null || true && \
    ln -sf /app/scripts/openclaw-approve.sh /usr/local/bin/openclaw-approve && \
    chmod +x /app/scripts/*.sh /usr/local/bin/openclaw-approve

# ✅ FINAL PATH (important)
ENV PATH="/opt/venv/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/data/.local/bin:/data/.npm-global/bin:/data/.bun/bin:/data/.bun/install/global/bin:/data/.claude/bin:/data/.kimi/bin"
# Set OpenClaw port and run app
ARG PORT=18790
EXPOSE ${PORT}
CMD ["bash", "/app/scripts/bootstrap.sh"]
