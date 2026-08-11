%%%-----------------------------------------------------------------
%%% asobi_terrain_flat.erl
%%%
%%% Provider de terreno plano para Asobi (behaviour
%%% `asobi_terrain_provider`). Todos los tiles del chunk son hierba
%%% caminable con elevación constante. Lleva este nombre a propósito:
%%% `asobi_terrain_flat` está en el allowlist por defecto de
%%% terrain_providers, así que se selecciona desde world.lua SIN tocar
%%% el sys.config.
%%%
%%% Selección desde world.lua:
%%%
%%%   function terrain_provider(config)
%%%       return { module = "asobi_terrain_flat", args = {} }
%%%   end
%%%
%%% Args opcionales:
%%%
%%%   - tile:      id de tile a emitir (por defecto 4 = hierba).
%%%   - elevation: elevación normalizada [0, 1] de cada tile
%%%                (por defecto 0.5). Se codifica a un byte.
%%%-----------------------------------------------------------------
-module(asobi_terrain_flat).
-behaviour(asobi_terrain_provider).

-export([init/1, load_chunk/2, generate_chunk/3]).

-define(DEFAULT_TILE, 4).       %% TILE_GRASS (ver asobi_terrain_perlin)
-define(FLAG_WALKABLE, 1).
-define(DEFAULT_ELEVATION, 0.5).

-moduledoc """
Flat terrain provider shipped under the default allowlisted name
`asobi_terrain_flat`. Every tile of every chunk is a walkable grass tile at
a constant elevation, which makes a clean empty surface for arenas, sandboxes
or world-editing workflows.

Config keys (all optional):

- `tile`: tile id to emit for every cell (default `4`, grass).
- `elevation`: normalized elevation in `[0, 1]` for every cell (default `0.5`).

See `asobi_terrain_provider` for the callback contract.
""".

%%%===================================================================
%%% asobi_terrain_provider callbacks
%%%===================================================================

-spec init(map()) -> {ok, map()}.
init(Config) ->
    State = #{
        tile => maps:get(tile, Config, ?DEFAULT_TILE),
        elevation => maps:get(elevation, Config, ?DEFAULT_ELEVATION)
    },
    {ok, State}.

-spec load_chunk({integer(), integer()}, map()) ->
    {error, not_found} | {error, not_found, map()}.
load_chunk({_X, _Y}, _State) ->
    {error, not_found}.

-spec generate_chunk({integer(), integer()}, integer(), map()) -> {ok, binary(), map()}.
generate_chunk({_X, _Y}, _Seed, State) ->
    #{tile := Tile, elevation := Elevation} = State,
    #{chunk_width := Width, chunk_height := Height} = asobi_terrain:default_format(),
    ElevationByte = trunc(clamp(Elevation, 0.0, 1.0) * 255),
    Tiles = maps:from_list([
        {{Lx, Ly}, {Tile, ?FLAG_WALKABLE, ElevationByte}}
        || Lx <- lists:seq(0, Width - 1), Ly <- lists:seq(0, Height - 1)
    ]),
    Bin = asobi_terrain:compress_chunk(asobi_terrain:encode_chunk(Tiles)),
    {ok, Bin, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

clamp(V, Min, _Max) when V < Min -> Min;
clamp(V, _Min, Max) when V > Max -> Max;
clamp(V, _Min, _Max) -> V.
