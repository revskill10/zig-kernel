# syntax=docker/dockerfile:1.7
FROM --platform=linux/amd64 debian:bookworm-slim AS zig-builder
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN curl --fail --location --retry 3 --output /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum --check \
 && mkdir /opt/zig \
 && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:${PATH}
WORKDIR /src
COPY build.zig build.zig.zon linker.ld README.md ./
COPY src ./src
COPY supervisor ./supervisor
COPY engine ./engine
COPY tests ./tests
COPY schemas ./schemas
COPY scripts ./scripts
COPY docs ./docs
COPY boot ./boot
COPY linker ./linker
COPY tools ./tools
COPY vendor/sqlite ./vendor/sqlite
RUN zig build sandbox-api -Doptimize=ReleaseSafe --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global

FROM --platform=linux/amd64 debian:bookworm-slim
COPY --from=zig-builder /src/zig-out/bin/zig-sandbox /usr/local/bin/zig-sandbox
RUN groupadd --system sandbox \
 && useradd --system --gid sandbox --no-create-home --shell /usr/sbin/nologin sandbox \
 && apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
USER sandbox:sandbox
EXPOSE 8080
# The image has one internal API port. Publish a different host port with
# Docker's `-p HOST_PORT:8080`; do not override the listener command.
HEALTHCHECK --interval=30s --timeout=3s --start-period=3s --retries=3 CMD curl --fail --silent http://127.0.0.1:8080/healthz
ENTRYPOINT ["/usr/local/bin/zig-sandbox"]
CMD ["serve", "--host=0.0.0.0", "--port=8080"]
