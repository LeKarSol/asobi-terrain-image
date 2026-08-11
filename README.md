# asobi-terrain-image

Imagen Docker autogestionada del servidor de juego **asobi** (widgrensit/asobi), construida directamente desde el release oficial en un tag concreto con los providers de terreno **horneados en el release**, renombrados a los nombres del allowlist por defecto para no tocar `sys.config`:

| Módulo | Implementación | Uso |
|--------|----------------|-----|
| `asobi_terrain_perlin` | OpenSimplex2 (antes `my_terrain_opensimplex2`) | mundos con terreno procedural |
| `asobi_terrain_flat` | Todo hierba caminable, elevación constante | arenas / planicies / sandbox |

Ambos son módulos del app `asobi` en el release: quedan en el ebin y en el boot script, así que funcionan en **modo embedded** sin `CODE_LOADING_MODE=interactive`, sin montar beams y sin override de `terrain_providers`.

La imagen vive en el GitHub Container Registry:

```
ghcr.io/lekarsol/asobi-terrain-image:<versión>
```

Se usa como imagen base normalmente, pero incluye el runtime completo (Erlang/OTP, Debian, tini) — no necesita nada más que un PostgreSQL y tus scripts Lua.


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

## Workflow de GitHub Actions

`.github/workflows/build.yml` (**Build image**) con disparo manual y
automático:

- **Manual** (→ **Actions** → **Build image**):
  - `asobi_ref`: tag (p. ej. `v0.73.9`) o SHA de `widgrensit/asobi`. Vacío =
    última release publicada. **No todos los commits/releases de Asobi generan
    imagen oficial ni interesan: este disparo manual elige cuándo construir.**
  - `image_tag`: tag de la imagen publicada (vacío = tag del ref).
- **Push de tag `asobi-*`**: construye la versión del tag (p. ej. `asobi-0.73.9`
  o `asobi-v0.73.9`), normalizada a `vX.Y.Z`.
- **Automático (schedule)**: cada 6 h consulta la última release publicada de
  `widgrensit/asobi` y construye si esa versión aún no está publicada en GHCR.

Publica en `ghcr.io/<owner>/asobi-terrain-image:<ref>` y `:latest`.

## Migrar un despliegue

Docker Compose: sustituye la imagen por la custom y elimina lo que ya no hace falta:

```yaml
  asobi:
    image: ghcr.io/USER/asobi-terrain-image:v0.73.9
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

La imagen incluye el runtime completo (Erlang/OTP, Debian, tini) y usa la
configuración del propio release de asobi vía variables de entorno.

## Providers

### asobi_terrain_perlin

Basado en OpenSimplex2 (24 gradientes uniformes, gradiente por hash de
coordenadas + seed). Args opcionales:

- `seed`: seed del mundo (default `0`).
- `scale`: escala de coordenadas; menor = continentes más grandes (default `0.015`).
- `octaves`: octavas de fBm (default `4`).
- `persistence` (default `0.5`), `lacunarity` (default `2.0`).
- `thresholds`: umbrales `deep_water/water/sand/grass/forest/rock` que
  mapean elevación a tile.

### asobi_terrain_flat

Todos los tiles de cada chunk son hierba caminable (tile `4`, flag `1`) con
elevación constante (default `0.5`). Args opcionales: `tile`, `elevation`.
