# asobi-terrain-image

**[English](README.md)**

Imagen Docker autogestionada del servidor de juego **asobi** (`widgrensit/asobi`), construida directamente desde el release oficial en un tag concreto con los providers de terreno **horneados en el release**, renombrados a los nombres del allowlist por defecto para no tocar `sys.config`:

| Módulo | Implementación | Uso |
|--------|----------------|-----|
| `asobi_terrain_perlin` | OpenSimplex2 (24 gradientes uniformes) | mundos con terreno procedural |
| `asobi_terrain_flat` | Todo hierba caminable, elevación constante | arenas / planicies / sandbox |

Ambos son módulos del app `asobi` en el release: quedan en el ebin y en el boot script, así que funcionan en **modo embedded** sin `CODE_LOADING_MODE=interactive`, sin montar beams y sin override de `terrain_providers`.

La imagen vive en el GitHub Container Registry:

```
ghcr.io/lekarsol/asobi-terrain-image:<versión>
```

Se usa como imagen base normalmente, pero incluye el runtime completo (Erlang/OTP 29, Debian trixie, tini) — no necesita nada más que un PostgreSQL y tus scripts Lua.

## Por qué

Asobi permite seleccionar un provider de terreno desde Lua mediante `terrain_provider/1`. El allowlist por defecto solo admite `asobi_terrain_flat` y `asobi_terrain_perlin`; usar un provider con otro nombre exigía añadirlo a `terrain_providers` en `sys.config`, montar el beam compilado y activar el modo interactive. Esta imagen hace innecesario todo eso: los nombres coinciden con el allowlist y el código va dentro del app.

## Uso desde Lua

`lua/world.lua`:

```lua
function terrain_provider(config)
    return {
        module = "asobi_terrain_perlin",
        args = { seed = 42 }
    }
end
```

Para un mundo plano:

```lua
function terrain_provider(config)
    return {
        module = "asobi_terrain_flat",
        args = { tile = 4, elevation = 0.5 }  -- args opcionales
    }
end
```

## Ejecutar la imagen

Pull:

```
docker pull ghcr.io/lekarsol/asobi-terrain-image:v0.77.1
```

### Migrar un despliegue

En Docker Compose, sustituye la imagen por la custom y elimina lo que ya no hace falta:

```yaml
  asobi:
    image: ghcr.io/lekarsol/asobi-terrain-image:v0.77.1
    volumes:
      - ./game:/app/game   # scripts Lua
    environment:
      ASOBI_PORT: 8084
      ASOBI_DB_HOST: db
      ASOBI_DB_NAME: asobi_prod
      ASOBI_DB_USER: asobi_user
      ASOBI_DB_PASSWORD: "clave"
      ASOBI_CORS_ORIGINS: "*"
      ASOBI_NODE_HOST: 0.0.0.0
      ERLANG_COOKIE: "tu-cookie"
```

La imagen usa la configuración del propio release de asobi vía variables de entorno, con los defaults de abajo horneados; se puede sobreescribir cualquiera de ellos.

### Variables de entorno

| Variable | Default | Notas |
|----------|---------|-------|
| `ASOBI_PORT` | `8084` | Puerto del juego (también `EXPOSE`d). |
| `ASOBI_NODE_HOST` | `127.0.0.1` | Pon `0.0.0.0` para aceptar conexiones externas. |
| `ASOBI_DB_HOST` | `db` | Host de PostgreSQL. |
| `ASOBI_DB_NAME` | `asobi` | Nombre de la base de datos. |
| `ASOBI_DB_USER` | `postgres` | Usuario de la base de datos. |
| `ASOBI_DB_PASSWORD` | `postgres` | Contraseña de la base de datos. |
| `ASOBI_GUEST_VERIFIER_PEPPER` | `""` | Pepper para el verifier de invitados. |
| `ASOBI_DB_SOCKET_OPTS` | `inet` | Opciones de socket para la conexión a la BD. |
| `ERLANG_COOKIE` | `asobi` | Cookie de distribución de Erlang. |

### Scripts Lua

Monta tus scripts de mundos en `/app/game` (declarado como `VOLUME`). El contenedor corre como el usuario `asobi`, así que asegúrate de que el mount sea legible por él.

## Build local

El Dockerfile toma un build arg `ASOBI_REF` (un tag `vX.Y.Z` de `widgrensit/asobi` o un SHA de commit). Por defecto usa la versión fijada actualmente.

```
docker build --build-arg ASOBI_REF=v0.77.1 -t ghcr.io/lekarsol/asobi-terrain-image:v0.77.1 .
```

## Releases y CI

`.github/workflows/build.yml` (**Build image**) construye y publica con tres disparadores:

| Disparador | Comportamiento |
|-----------|----------------|
| **Manual** (→ **Actions** → **Build image**) | `asobi_ref` = tag (`v0.73.9`), SHA, o vacío para la última release publicada; `image_tag` = tag de la imagen publicada (vacío = tag del ref). **No todos los commits/releases de Asobi generan imagen oficial ni interesan: este disparo manual elige cuándo construir.** |
| **Push de tag `asobi-*`** | Construye esa versión (`asobi-0.73.9` o `asobi-v0.73.9`), normalizada a `vX.Y.Z`. |
| **Automático (schedule)** | Cada 6 h consulta la última release publicada de `widgrensit/asobi` y construye solo si esa versión aún no está publicada en GHCR. |

Publica en `ghcr.io/<owner>/asobi-terrain-image:<ref>` y `:latest`, con cache de layers de GHCR.

### bump-version.sh

`bump-version.sh` automatiza el bump de versión y el lanzamiento del build en CI:

```
./bump-version.sh          # usa la última release publicada de Asobi
./bump-version.sh 0.73.9   # fija una versión concreta
./bump-version.sh --force  # recrea el tag aunque exista, forzando un rebuild real
```

Comprueba que el tag existe aguas arriba, sube el `ASOBI_REF` por defecto en el Dockerfile, commitea y hace push a `main`, y luego hace push del tag `asobi-vX.Y.Z` que dispara el workflow. `--force` además toca `.rebuild-trigger` para que Buildx reconstruya desde el clone en adelante en vez de reutilizar la cache.

## Providers

### asobi_terrain_perlin

Núcleo OpenSimplex2: 24 gradientes uniformemente distribuidos (cada 15°) elegidos por hash de coordenadas de rejilla + seed, así que la seed cambia de verdad el patrón del terreno. Todos los args son opcionales:

- `seed`: seed del mundo (default `0`).
- `scale`: escala de coordenadas; menor = continentes más grandes (default `0.015`).
- `octaves`: octavas de fBm (default `4`).
- `persistence` (default `0.5`).
- `lacunarity` (default `2.0`).
- `thresholds`: umbrales `deep_water/water/sand/grass/forest/rock` que mapean elevación a tile. Defaults: `0.30 / 0.40 / 0.45 / 0.70 / 0.85 / 0.95`.

Tiles: agua profunda (1), agua (2), arena (3), hierba (4), bosque (5), roca (6), nieve (7); los tiles de agua se marcan como no caminables.

### asobi_terrain_flat

Todos los tiles de cada chunk son hierba caminable (tile `4`, flag `1`) con elevación constante (default `0.5`). Args opcionales: `tile`, `elevation` (normalizada `[0, 1]`).