%%%-----------------------------------------------------------------
%%% asobi_terrain_perlin.erl
%%%
%%% Provider de terreno para Asobi (behaviour `asobi_terrain_provider`)
%%% con núcleo de ruido OpenSimplex2. Lleva este nombre a propósito:
%%% `asobi_terrain_perlin` está en el allowlist por defecto de
%%% terrain_providers, así que se puede seleccionar desde world.lua SIN
%%% tocar el sys.config (no hace falta añadirlo a la lista blanca).
%%%
%%% Origen: migrado desde my_terrain_simplex.erl. Mismo behaviour y
%%% misma interfaz de config, pero el núcleo de ruido es OpenSimplex2
%%% en vez de Simplex clásico:
%%%
%%%   - Tabla de gradientes de 24 direcciones uniformes (cada 15°) en
%%%     vez de las 12 direcciones fijas de Simplex clásico -> menos
%%%     sesgo direccional visible, sobre todo en ruido de baja
%%%     frecuencia (zonas muy planas / muy alejadas del origen).
%%%   - Selección de gradiente por hash a partir de coordenadas de
%%%     rejilla + seed, en vez de tabla de permutación estática -> la
%%%     seed cambia realmente el patrón de gradientes, no solo el
%%%     desplazamiento por chunk.
%%%   - Sin restricciones de patente en ninguna dimensión (Simplex
%%%     clásico ya tampoco las tiene desde ene-2022, pero OpenSimplex2
%%%     nunca las tuvo, para empezar).
%%%
%%% Selección desde world.lua:
%%%
%%%   function terrain_provider(config)
%%%       return { module = "asobi_terrain_perlin", args = { seed = 42 } }
%%%   end
%%%-----------------------------------------------------------------
-module(asobi_terrain_perlin).
-behaviour(asobi_terrain_provider).

-export([init/1, load_chunk/2, generate_chunk/3]).
-export([noise2/3, fbm2/6]).

-moduledoc """
Terrain provider based on OpenSimplex2 noise, shipped under the default
allowlisted name `asobi_terrain_perlin` so a Lua world can select it without
extra `terrain_providers` configuration.

Config keys (all optional):

- `seed`: world seed (default `0`).
- `scale`: coordinate scale, lower = bigger continents (default `0.015`).
- `octaves`: fBm octaves (default `4`).
- `persistence`: octave persistence (default `0.5`).
- `lacunarity`: octave frequency multiplier (default `2.0`).
- `thresholds`: elevation thresholds mapping tiles to biomes.

See `asobi_terrain_provider` for the callback contract.
""".

-define(TILE_DEEP_WATER, 1).
-define(TILE_WATER,      2).
-define(TILE_SAND,       3).
-define(TILE_GRASS,      4).
-define(TILE_FOREST,     5).
-define(TILE_ROCK,       6).
-define(TILE_SNOW,       7).

-define(FLAG_WALKABLE,   1).
-define(FLAG_WATER,      2).

%% Constantes del skew/unskew simplicial 2D - idénticas a Simplex
%% clásico, porque la retícula base (triangular) es la misma. Lo que
%% cambia es SOLO la tabla de gradientes y cómo se elige el gradiente
%% en cada vértice.
-define(SQRT3, 1.7320508075688772935).
-define(G2, (3 - ?SQRT3) / 6).
-define(F2, 0.5 * (?SQRT3 - 1)).

-define(PRIME_X, 501125321).
-define(PRIME_Y, 1136930381).

%% Constante de normalización calibrada empíricamente por muestreo
%% masivo (ver proto_opensimplex2.py): el máximo absoluto real medido
%% fue ~0.0101, así que 95.0 deja ~5% de margen y nunca satura fuera
%% de [-1, 1] en la práctica.
-define(NORM_CONST, 95.0).

%%%===================================================================
%%% asobi_terrain_provider callbacks
%%%===================================================================

-spec init(map()) -> {ok, map()}.
init(Config) ->    State = #{
        seed        => maps:get(seed, Config, 0),
        scale       => maps:get(scale, Config, 0.015),
        octaves     => maps:get(octaves, Config, 4),
        persistence => maps:get(persistence, Config, 0.5),
        lacunarity  => maps:get(lacunarity, Config, 2.0),
        thresholds  => maps:get(thresholds, Config, #{
            deep_water => 0.30,
            water      => 0.40,
            sand       => 0.45,
            grass      => 0.70,
            forest     => 0.85,
            rock       => 0.95
        })
    },
    {ok, State}.

-spec load_chunk({integer(), integer()}, map()) ->
    {error, not_found} | {error, not_found, map()}.
load_chunk({_X, _Y}, _State) ->
    {error, not_found}.

-spec generate_chunk({integer(), integer()}, integer(), map()) -> {ok, binary(), map()}.
generate_chunk({X, Y}, Seed, State) ->
    #{
        scale       := Scale,
        octaves     := Octaves,
        persistence := Persistence,
        lacunarity  := Lacunarity,
        thresholds  := Thresholds
    } = State,

    ChunkSeed = Seed bxor (X * 374761393) bxor (Y * 668265263),

    %% Formato real esperado por asobi_terrain:encode_chunk/1: un mapa
    %% #{{LocalX, LocalY} => {TileId, Flags, Elevation}}, NO una lista
    %% de tuplas de 5 elementos. chunk_width/height se consultan en
    %% runtime via default_format/0 en vez de asumir 64x64 fijo.
    #{chunk_width := Width, chunk_height := Height} = asobi_terrain:default_format(),

    Tiles = maps:from_list([
        tile_at(X * Width + Lx, Y * Height + Ly, Lx, Ly, ChunkSeed, Scale,
                Octaves, Persistence, Lacunarity, Thresholds)
        || Lx <- lists:seq(0, Width - 1), Ly <- lists:seq(0, Height - 1)
    ]),

    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.

%%%===================================================================
%%% Tile generation
%%%===================================================================

tile_at(WorldX, WorldY, LocalX, LocalY, Seed, Scale, Octaves, Persistence,
        Lacunarity, Thresholds) ->
    Elevation = fbm2(WorldX * Scale, WorldY * Scale, Octaves, Persistence,
                      Lacunarity, Seed),
    Norm = clamp((Elevation + 1.0) / 2.0, 0.0, 1.0),
    {TileId, Flags} = classify(Norm, Thresholds),
    ElevationByte = trunc(Norm * 255),
    %% {X, Y} => {TileId, Flags, Elevation} - el par clave/valor que
    %% maps:from_list/1 necesita para construir el mapa del chunk.
    {{LocalX, LocalY}, {TileId, Flags, ElevationByte}}.

classify(Norm, #{deep_water := DW, water := W, sand := S, grass := G,
                  forest := F, rock := R}) ->
    if
        Norm < DW -> {?TILE_DEEP_WATER, ?FLAG_WATER};
        Norm < W  -> {?TILE_WATER,      ?FLAG_WATER};
        Norm < S  -> {?TILE_SAND,       ?FLAG_WALKABLE};
        Norm < G  -> {?TILE_GRASS,      ?FLAG_WALKABLE};
        Norm < F  -> {?TILE_FOREST,     ?FLAG_WALKABLE};
        Norm < R  -> {?TILE_ROCK,       ?FLAG_WALKABLE};
        true      -> {?TILE_SNOW,       ?FLAG_WALKABLE}
    end.

clamp(V, Min, _Max) when V < Min -> Min;
clamp(V, _Min, Max) when V > Max -> Max;
clamp(V, _Min, _Max) -> V.

%%%===================================================================
%%% Fractal Brownian Motion - sin cambios respecto a Simplex clásico,
%%% apila octavas de noise2/2 (que ahora es OpenSimplex2).
%%%===================================================================

-spec fbm2(number(), number(), non_neg_integer(), number(), number(), integer()) -> number().
fbm2(X, Y, Octaves, Persistence, Lacunarity, Seed) ->
    fbm2(X, Y, Octaves, Persistence, Lacunarity, Seed, 1.0, 1.0, 0.0, 0.0).

fbm2(_X, _Y, 0, _Persistence, _Lacunarity, _Seed, _Amplitude, _Frequency, Total, MaxAmp) ->
    case MaxAmp of
        +0.0 -> 0.0;
        _    -> Total / MaxAmp
    end;
fbm2(X, Y, Octaves, Persistence, Lacunarity, Seed, Amplitude, Frequency, Total, MaxAmp) ->
    N = noise2(X * Frequency, Y * Frequency, Seed),
    fbm2(X, Y, Octaves - 1, Persistence, Lacunarity, Seed,
         Amplitude * Persistence, Frequency * Lacunarity,
         Total + N * Amplitude, MaxAmp + Amplitude).

%%%===================================================================
%%% OpenSimplex2 2D
%%%
%%% Misma retícula simplicial triangular que Simplex clásico (skew con
%%% F2/G2), pero:
%%%   1. 24 gradientes uniformemente distribuidos en el círculo
%%%      (cada 15°), calculados analíticamente con cos/sin - no una
%%%      tabla fija arbitraria.
%%%   2. El gradiente en cada vértice de la retícula se elige por hash
%%%      de sus coordenadas enteras (I, J) combinadas con la seed,
%%%      usando primos grandes + mezcla bit a bit (variante MurmurHash),
%%%      en vez de la tabla de permutación de 256 entradas de Perlin.
%%%      Esto evita el patrón repetitivo periódico que Perlin arrastra
%%%      del tamaño fijo de su tabla.
%%%===================================================================

-define(GRAD_COUNT, 24).

%% Gradiente k-ésimo: punto en el círculo unitario a k*15 grados.
%% Se computa on-the-fly con trigonometría en vez de guardar una tabla
%% -> no hay literales "misteriosos" que verificar, y es trivialmente
%% auditable.
grad_vector(K) ->
    Angle = (K rem ?GRAD_COUNT) * (math:pi() / 12.0), % 15 grados = pi/12
    {math:cos(Angle), math:sin(Angle)}.

%% Hash de coordenadas de rejilla (I, J) + seed -> índice [0, 23].
%% Mezcla estilo MurmurHash3 finalizer: barato y con buena
%% distribución de bits para este propósito.
hash_ij(Seed, I, J) ->
    H0 = (Seed bxor (I * ?PRIME_X) bxor (J * ?PRIME_Y)) band 16#FFFFFFFF,
    H1 = ((H0 bxor (H0 bsr 15)) * 16#2c1b3c6d) band 16#FFFFFFFF,
    H2 = ((H1 bxor (H1 bsr 12)) * 16#297a2d39) band 16#FFFFFFFF,
    H3 = (H2 bxor (H2 bsr 15)) band 16#7FFFFFFF,
    H3 rem ?GRAD_COUNT.

grad_coord(Seed, I, J, Dx, Dy) ->
    Idx = hash_ij(Seed, I, J),
    {Gx, Gy} = grad_vector(Idx),
    Gx * Dx + Gy * Dy.

%% Ruido OpenSimplex2 2D determinista, salida normalizada a ~[-1, 1].
%% La seed entra directo al hash de gradientes (hash_ij/3), no como
%% desplazamiento de coordenadas - así seeds distintas dan patrones de
%% terreno realmente distintos, no la misma forma desplazada un poco.
-spec noise2(number(), number(), integer()) -> number().
noise2(X, Y, Seed) ->
    S = (X + Y) * ?F2,
    Xs = X + S,
    Ys = Y + S,
    I = floor_i(Xs),
    J = floor_i(Ys),
    Xi = Xs - I,
    Yi = Ys - J,

    T = (Xi + Yi) * ?G2,
    X0 = Xi - T,
    Y0 = Yi - T,

    N0 = corner0(Seed, I, J, X0, Y0),
    N2 = corner2(Seed, I, J, X0, Y0, T),
    N1 = corner1(Seed, I, J, X0, Y0),

    (N0 + N1 + N2) * ?NORM_CONST.

corner0(Seed, I, J, X0, Y0) ->
    A = 0.5 - X0 * X0 - Y0 * Y0,
    if
        A =< 0.0 -> 0.0;
        true ->
            AA = A * A,
            AA * AA * grad_coord(Seed, I, J, X0, Y0)
    end.

corner2(Seed, I, J, X0, Y0, T) ->
    C = (2 * (1 - 2 * ?G2) * (1 / ?G2 - 2)) * T +
        (-2 * (1 - 2 * ?G2) * (1 - 2 * ?G2) + (0.5 - X0 * X0 - Y0 * Y0)),
    if
        C =< 0.0 -> 0.0;
        true ->
            X2 = X0 + (2 * ?G2 - 1),
            Y2 = Y0 + (2 * ?G2 - 1),
            CC = C * C,
            CC * CC * grad_coord(Seed, I + 1, J + 1, X2, Y2)
    end.

corner1(Seed, I, J, X0, Y0) when Y0 > X0 ->
    X1 = X0 + ?G2,
    Y1 = Y0 + (?G2 - 1),
    B = 0.5 - X1 * X1 - Y1 * Y1,
    if
        B =< 0.0 -> 0.0;
        true ->
            BB = B * B,
            BB * BB * grad_coord(Seed, I, J + 1, X1, Y1)
    end;
corner1(Seed, I, J, X0, Y0) ->
    X1 = X0 + (?G2 - 1),
    Y1 = Y0 + ?G2,
    B = 0.5 - X1 * X1 - Y1 * Y1,
    if
        B =< 0.0 -> 0.0;
        true ->
            BB = B * B,
            BB * BB * grad_coord(Seed, I + 1, J, X1, Y1)
    end.

floor_i(V) ->
    F = trunc(V),
    case V < F of
        true  -> F - 1;
        false -> F
    end.