# asobi-terrain-image

**[Español](README-ES.md)**

Self-managed Docker image of the **asobi** game server (`widgrensit/asobi`), built directly from a pinned official release tag with custom terrain providers **baked into the release** under the default allowlist names, so no `sys.config` edits are needed:

| Module | Implementation | Use |
|--------|----------------|-----|
| `asobi_terrain_perlin` | OpenSimplex2 (24 uniform gradients) | worlds with procedural terrain |
| `asobi_terrain_flat` | Constant-elevation walkable grass | arenas / plains / sandboxes |

Both are modules of the `asobi` app inside the release: they live in the ebin and in the boot script, so they work in **embedded mode** with no `CODE_LOADING_MODE=interactive`, no mounted beams, and no `terrain_providers` override.

The image is published to the GitHub Container Registry:

```
ghcr.io/lekarsol/asobi-terrain-image:<version>
```

It is normally used as the base image, but it includes the full runtime (Erlang/OTP 29, Debian trixie, tini) — it only needs a PostgreSQL instance and your Lua scripts.

## Why

Asobi lets a world pick a terrain provider from Lua through `terrain_provider/1`. The default allowlist only accepts `asobi_terrain_flat` and `asobi_terrain_perlin`; any other provider name required adding it to `terrain_providers` in `sys.config`, mounting the compiled beam, and enabling interactive mode. This image removes all of that: the module names match the allowlist and the code is bundled inside the app.

## Using from Lua

`lua/world.lua`:

```lua
function terrain_provider(config)
    return {
        module = "asobi_terrain_perlin",
        args = { seed = 42 }
    }
end
```

For a flat world:

```lua
function terrain_provider(config)
    return {
        module = "asobi_terrain_flat",
        args = { tile = 4, elevation = 0.5 }  -- optional args
    }
end
```

## Running the image

Pull:

```
docker pull ghcr.io/lekarsol/asobi-terrain-image:v0.77.1
```

### Migrating a deployment

In Docker Compose, swap the official image for the custom one and drop what is no longer needed:

```yaml
  asobi:
    image: ghcr.io/lekarsol/asobi-terrain-image:v0.77.1
    volumes:
      - ./game:/app/game   # Lua scripts
    environment:
      ASOBI_PORT: 8084
      ASOBI_DB_HOST: db
      ASOBI_DB_NAME: asobi_prod
      ASOBI_DB_USER: asobi_user
      ASOBI_DB_PASSWORD: "secret"
      ASOBI_CORS_ORIGINS: "*"
      ASOBI_NODE_HOST: 0.0.0.0
      ERLANG_COOKIE: "your-cookie"
```

The image uses the release's own configuration through environment variables, with the defaults below baked in; override any of them.

### Environment variables

| Variable | Default | Notes |
|----------|---------|-------|
| `ASOBI_PORT` | `8084` | Game port (also `EXPOSE`d). |
| `ASOBI_NODE_HOST` | `127.0.0.1` | Set to `0.0.0.0` to accept external connections. |
| `ASOBI_DB_HOST` | `db` | PostgreSQL host. |
| `ASOBI_DB_NAME` | `asobi` | Database name. |
| `ASOBI_DB_USER` | `postgres` | Database user. |
| `ASOBI_DB_PASSWORD` | `postgres` | Database password. |
| `ASOBI_GUEST_VERIFIER_PEPPER` | `""` | Pepper for the guest verifier. |
| `ASOBI_DB_SOCKET_OPTS` | `inet` | Socket options for the DB connection. |
| `ERLANG_COOKIE` | `asobi` | Erlang distribution cookie. |

### Lua scripts

Mount your world scripts at `/app/game` (declared as a `VOLUME`). The container runs as the `asobi` user, so make sure the mount is readable by it.

## Building locally

The Dockerfile takes an `ASOBI_REF` build arg (a `widgrensit/asobi` tag `vX.Y.Z` or a commit SHA). It defaults to the currently pinned version.

```
docker build --build-arg ASOBI_REF=v0.77.1 -t ghcr.io/lekarsol/asobi-terrain-image:v0.77.1 .
```

## Releasing and CI

`.github/workflows/build.yml` (**Build image**) builds and publishes on three triggers:

| Trigger | Behavior |
|---------|----------|
| **Manual** (→ **Actions** → **Build image**) | `asobi_ref` = tag (`v0.73.9`), SHA, or empty for the latest published release; `image_tag` = tag of the published image (empty = the ref tag). **Not every Asobi commit/release is worth building: this manual trigger decides when.** |
| **Tag push `asobi-*`** | Builds that version (`asobi-0.73.9` or `asobi-v0.73.9`), normalized to `vX.Y.Z`. |
| **Schedule** (every 6 h) | Checks the latest `widgrensit/asobi` release and builds only if that version is not yet published on GHCR. |

It pushes to `ghcr.io/<owner>/asobi-terrain-image:<ref>` and `:latest`, using the GHCR layer cache.

### bump-version.sh

`bump-version.sh` automates a version bump and the CI launch:

```
./bump-version.sh          # use the latest published Asobi release
./bump-version.sh 0.73.9   # pin a specific version
./bump-version.sh --force  # recreate the tag even if it exists, forcing a real rebuild
```

It verifies the tag exists upstream, bumps the default `ASOBI_REF` in the Dockerfile, commits and pushes to `main`, then pushes the `asobi-vX.Y.Z` tag that triggers the workflow. `--force` also touches `.rebuild-trigger` so Buildx rebuilds from the clone onwards instead of reusing the cache.

## Providers

### asobi_terrain_perlin

OpenSimplex2 core: 24 uniformly distributed gradients (every 15°) selected by hashing grid coordinates + seed, so the seed genuinely changes the terrain pattern. All args are optional:

- `seed`: world seed (default `0`).
- `scale`: coordinate scale; lower = bigger continents (default `0.015`).
- `octaves`: fBm octaves (default `4`).
- `persistence` (default `0.5`).
- `lacunarity` (default `2.0`).
- `thresholds`: elevation thresholds `deep_water/water/sand/grass/forest/rock` mapping elevation to tile. Defaults: `0.30 / 0.40 / 0.45 / 0.70 / 0.85 / 0.95`.

Tiles: deep water (1), water (2), sand (3), grass (4), forest (5), rock (6), snow (7); water tiles are flagged not walkable.

### asobi_terrain_flat

Every tile of every chunk is walkable grass (tile `4`, flag `1`) at constant elevation (default `0.5`). Optional args: `tile`, `elevation` (normalized `[0, 1]`).
