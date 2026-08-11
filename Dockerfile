# Imagen custom de Asobi con los providers de terreno horneados.
#
# Rebuild desde el tag fuente de widgrensit/asobi (ARG ASOBI_REF) con
# `asobi_terrain_perlin` (OpenSimplex2) y `asobi_terrain_flat` inyectados
# en src/world/, de modo que quedan dentro del app del release y en el boot
# script (modo embedded, sin CODE_LOADING_MODE ni sys.config extra).
#
# Los nombres coinciden con el allowlist por defecto de terrain_providers
# ([asobi_terrain_flat, asobi_terrain_perlin]), así que un mundo Lua los
# selecciona con `module = "asobi_terrain_perlin"` sin tocar configuración.
#
# Build:
#   docker build --build-arg ASOBI_REF=v0.73.9 -t ghcr.io/USER/asobi-terrain-image:v0.73.9 .

# --- Builder: igual que el Dockerfile oficial -------------------------------
FROM erlang:29.0.4-slim AS builder

ARG ASOBI_REF=v0.75.2
ARG ASOBI_REPO=https://github.com/widgrensit/asobi.git

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install rebar3
RUN curl -fsSL https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Clonar el ref concreto (acepta tags vX.Y.Z o SHAs). Los providers se
# copian ANTES de compilar el app para que queden dentro del release.
RUN if git ls-remote --tags --exit-code ${ASOBI_REPO} ${ASOBI_REF} >/dev/null 2>&1; then \
        git clone --depth 1 --branch ${ASOBI_REF} ${ASOBI_REPO} .; \
    else \
        git init -q && git remote add origin ${ASOBI_REPO} && \
        git fetch --depth 1 origin ${ASOBI_REF} && git checkout -q ${ASOBI_REF}; \
    fi

# Providers custom (renombrados a los nombres del allowlist por defecto).
COPY providers/asobi_terrain_perlin.erl src/world/asobi_terrain_perlin.erl
COPY providers/asobi_terrain_flat.erl   src/world/asobi_terrain_flat.erl

# Compilar dependencias y montar el release (modo prod, embedded).
RUN rebar3 compile --deps_only
RUN rebar3 as prod release

# --- Runtime: igual que el Dockerfile oficial -------------------------------
# Debe coincidir con la base Debian del builder (trixie) para que la GLIBC
# enlazada en runtime exista.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libncurses6 libssl3 libtinfo6 ca-certificates tini && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r asobi && useradd -r -g asobi -d /app asobi

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/asobi/ ./

# Game scripts mount point
RUN mkdir -p /app/game && chown -R asobi:asobi /app
VOLUME ["/app/game"]

USER asobi
EXPOSE 8084

ENV ASOBI_PORT=8084 \
    ASOBI_NODE_HOST=127.0.0.1 \
    ASOBI_DB_HOST=db \
    ASOBI_DB_NAME=asobi \
    ASOBI_DB_USER=postgres \
    ASOBI_DB_PASSWORD=postgres \
    ASOBI_GUEST_VERIFIER_PEPPER="" \
    ASOBI_DB_SOCKET_OPTS=inet \
    ERLANG_COOKIE=asobi

ENTRYPOINT ["tini", "--"]
CMD ["bin/asobi", "foreground"]
