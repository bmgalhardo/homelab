FROM python:3.13-slim

ARG TARGETARCH
ARG OMNICTL_VERSION=v1.11.0
ARG TALOSCTL_VERSION=v1.14.0

ADD --chmod=755 https://github.com/siderolabs/omni/releases/download/${OMNICTL_VERSION}/omnictl-linux-${TARGETARCH} /usr/local/bin/omnictl
ADD --chmod=755 https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-${TARGETARCH} /usr/local/bin/talosctl

COPY --from=ghcr.io/astral-sh/uv:0.12.22 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --locked --no-dev --no-install-project
COPY src/app ./src/app
RUN uv sync --locked --no-dev

ENTRYPOINT ["/app/.venv/bin/argus"]
