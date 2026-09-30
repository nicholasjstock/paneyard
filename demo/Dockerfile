# The recorded demo's container: this app's Ruby, a pinned herdr running
# headless, Claude Code, Hunk, and an X display to film them on. See
# docs/demo-recording-plan.md. Built by demo/bin/record from a staged context
# (Gemfile, Gemfile.lock, .ruby-version and demo/), never the whole repo; the
# repo itself is mounted at /work/paneyard at run time.
FROM ruby:4.0.1-slim-trixie

ARG HERDR_VERSION=0.9.3
ARG CLAUDE_CODE_VERSION=2.1.285
ARG HUNK_VERSION=0.22.0
# The host user's uid, so files written into the mounted repo (tmp/,
# tmp/demo-output/) belong to them.
ARG DEMO_UID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    BUNDLE_WITHOUT=development:test \
    DISABLE_AUTOUPDATER=1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git libyaml-dev pkg-config procps sqlite3 \
    nodejs npm \
    xvfb xterm openbox x11-utils xdotool ffmpeg \
    fonts-jetbrains-mono fonts-symbola \
  && rm -rf /var/lib/apt/lists/*

# herdr publishes a static binary per release and architecture.
RUN curl -fsSL -o /usr/local/bin/herdr \
    "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-$(uname -m)" \
  && chmod +x /usr/local/bin/herdr \
  && herdr --version

# The real CLI lives under /opt/claude-code; /usr/local/bin/claude is a
# dispatcher that can swap in the rehearsal stand-in (demo/bin/claude).
RUN npm install -g --prefix /opt/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
  && npm install -g "hunkdiff@${HUNK_VERSION}" \
  && /opt/claude-code/bin/claude --version \
  && hunk --version
COPY demo/bin/claude /usr/local/bin/claude

COPY Gemfile Gemfile.lock .ruby-version /tmp/gems/
RUN cd /tmp/gems && bundle install --jobs 4 && rm -rf /tmp/gems

# The terminal the herdr client is filmed in. kitty, not xterm: xterm crops a
# fallback glyph wider than one cell, which cut Claude Code's ⏺ marker in
# half; kitty scales symbols into the cell. It renders with OpenGL, which
# Mesa provides in software under Xvfb. Noto Sans Symbols 2 supplies ⏺ ⎿ etc.
# A machine-id quiets kitty's D-Bus warnings.
RUN apt-get update \
  && apt-get install -y --no-install-recommends kitty libgl1-mesa-dri fonts-noto-core \
  && rm -rf /var/lib/apt/lists/* \
  && echo 5f3c0a1e9b2d4c6e8a7f1b3d5c7e9a0b > /etc/machine-id

RUN useradd --create-home --uid "${DEMO_UID}" --shell /bin/bash demo \
  && mkdir -p /work/demo /work/paneyard \
  && chown demo:demo /work/demo
COPY --chown=demo:demo demo/herdr/config.toml /home/demo/.config/herdr/config.toml

USER demo
ENV SHELL=/bin/bash \
    BOOTSNAP_CACHE_DIR=/tmp/bootsnap
WORKDIR /work/paneyard
