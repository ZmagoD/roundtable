# The image every sandboxed participant starts from. `Roundtable.Sandbox`
# builds it and tags it by this file's hash, so changing anything here is what
# makes the next sandboxed turn rebuild it.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps python3 ripgrep \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @openai/codex opencode-ai @xai-official/grok \
 && npm cache clean --force

# Vibe wants a newer Python than Debian ships; uv brings its own.
COPY --from=ghcr.io/astral-sh/uv:0.9.5 /uv /usr/local/bin/uv
ENV UV_TOOL_DIR=/opt/uv/tools UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv tool install --python 3.12 mistral-vibe && chmod -R a+rX /opt/uv

# Turns run as the human's own uid so files in the project stay theirs. That
# uid has no account here, so the home is shared and sticky rather than owned.
ENV HOME=/home/agent
RUN mkdir -p /home/agent && chmod 1777 /home/agent
