-- RailroaderRVTest shared constants.
--
-- This module has no dependency on RailroaderMP or Architect.  BuildingCraft
-- and Railroader are required runtime dependencies for the light/locomotive
-- adapters below.
-- The server side owns all world mutation; these values are shared only so
-- that the client request and server layout use the same contract.

RailroaderRV = RailroaderRV or {}
RailroaderRV.Constants = RailroaderRV.Constants or {}

local C = RailroaderRV.Constants

C.MOD_ID = "RailroaderRVTest"
C.NAMESPACE = "RailroaderRV"
C.COMMAND_GENERATE = "Generate"
C.COMMAND_FINAL_RELOCATE = "FinalRelocate"
C.COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
C.COMMAND_RV_ENTER = "EnterRV"
C.COMMAND_RV_EXIT = "ExitRV"
C.COMMAND_RV_TELEPORT = "RVTeleport"
C.RV_MAP_KEY = "RailroaderRVTest.TrainMap"
C.TECH_VERSION = "0.1.1-tech"

-- The current test button always targets this server-selected destination.
-- Clients never send or choose these coordinates.
C.TELEPORT_X = 20050
C.TELEPORT_Y = 2050
C.TELEPORT_Z = 0

-- The generated room is an RV destination, not a Railroader room.  The
-- persistent map uses a half-open 100x100 XY region so that the reverse lookup
-- is based on the passenger's coordinate and never on an IsoRoom/id value.
C.RV_REGION_SIZE = 100
C.RV_REGION_MIN_OFFSET_X = -50
C.RV_REGION_MIN_OFFSET_Y = -50
C.RV_REGION_MAX_OFFSET_X = C.RV_REGION_MIN_OFFSET_X + C.RV_REGION_SIZE
C.RV_REGION_MAX_OFFSET_Y = C.RV_REGION_MIN_OFFSET_Y + C.RV_REGION_SIZE
C.RV_MOUNT_REACH = 2.0
-- Kept as an adapter-facing alias for older callers.  Both client and server
-- must measure from the Railroader body hull, never from the locomotive centre.
C.RV_ENTER_RANGE = C.RV_MOUNT_REACH
C.RV_STOPPED_SPEED = 0.05
C.RV_MAX_PASSENGERS = 5

-- Railroader's shared depot contract is the safe last-resort destination when
-- an RV coordinate is still occupied but every persisted train mapping is
-- unusable.  The server prefers RR.Spawn.DEPOT and only uses these coordinates
-- when the official route modules are unavailable during recovery.
C.RV_FALLBACK_X = 11606
C.RV_FALLBACK_Y = 9851
C.RV_FALLBACK_Z = 0

-- The destructive clear footprint is an inclusive 101 x 101 square, centered around the
-- destination anchor.  The server walks every valid z level when applying it.
C.CLEAR_MIN_OFFSET_X = -50
C.CLEAR_MAX_OFFSET_X = 50
C.CLEAR_MIN_OFFSET_Y = -50
C.CLEAR_MAX_OFFSET_Y = 50
C.CLEAR_ALL_Z = true
-- IsoWorld.isValidSquare() accepts the inclusive B42.20 vertical range
-- -32..31.  The server still visits only already-loaded squares, so this
-- does not manufacture a 64-level column while clearing an abandoned plot.
C.CLEAR_MIN_Z = -32
C.CLEAR_MAX_Z = 31

-- The generated cabin has a six-cell east/west interior and a forty-cell
-- north/south interior.  The one-cell wall ring therefore spans 7 x 41
-- coordinates.  The even dimensions are centered on the target cell: the
-- interior runs x=-2..+3 and y=-19..+20 relative to the anchor, so the
-- final destination (anchor + 0.5, anchor + 0.5) is the geometric center.
C.INTERIOR_MIN_OFFSET_X = -2
C.INTERIOR_MAX_OFFSET_X = 3
C.INTERIOR_MIN_OFFSET_Y = -19
C.INTERIOR_MAX_OFFSET_Y = 20
C.WALL_MIN_OFFSET_X = C.INTERIOR_MIN_OFFSET_X
C.WALL_MAX_OFFSET_X = C.INTERIOR_MAX_OFFSET_X + 1
C.WALL_MIN_OFFSET_Y = C.INTERIOR_MIN_OFFSET_Y
C.WALL_MAX_OFFSET_Y = C.INTERIOR_MAX_OFFSET_Y + 1
C.ROOF_Z_OFFSET = 1

-- Direction-independent object placement contract.  Layout.lua resolves
-- these offsets into absolute coordinates for the server worker.
C.LAMP_OFFSET = { x = -2, y = 0, z = 0 }
C.COUNTER_OFFSET = { x = 1, y = 0, z = 0 }
C.SINK_OFFSET = { x = 1, y = 0, z = 0 }
C.RAIN_COLLECTOR_OFFSET = { x = 1, y = 0, z = 1 }
C.GENERATOR_OFFSET = { x = -1, y = 0, z = 1 }

-- BuildCraft's ordinary, resource-free sprites are used as the visual
-- vocabulary for the static test.  The server may choose the directional
-- variant when it builds an IsoThumpable/IsoObject.
C.SPRITES = {
    -- The interior floor is the exact green carpet tile requested for the
    -- room.  The roof remains an ordinary flat wood floor on z+1.
    woodFloor = { sprite = "floors_interior_carpet_01_5", northSprite = "floors_interior_carpet_01_5" },
    roofFloor = { sprite = "floors_interior_tilesandwood_01_40", northSprite = "floors_interior_tilesandwood_01_40" },
    -- Tile definitions pair 20 (WallW) with 21 (WallN) for straight walls.
    -- 22 is the NW single corner strip (WallNW); 23 is the matching SE
    -- single corner strip (WallSE).
    wall = { sprite = "walls_interior_house_03_20", northSprite = "walls_interior_house_03_21" },
    wallNW = { sprite = "walls_interior_house_03_22", northSprite = "walls_interior_house_03_22" },
    wallSE = { sprite = "walls_interior_house_03_23", northSprite = "walls_interior_house_03_23" },
    -- BuildingCraft's "Custom House Light Switch 1" for the west wall.  The
    -- tile is supplied by the required runtime dependency; do not replace it
    -- with either of BuildingCraft's system-house switches or a vanilla lamp.
    wallLamp = { sprite = "BuildingCraft_Light_17", northSprite = "BuildingCraft_Light_17" },
    -- B42.20's map-object conversion uses 122 for the large collector.  It
    -- carries the generated entity/FluidContainer component; 52/53 are the
    -- old map-state sprites and are not safe construction sprites here.
    rainCollector = { sprite = "carpentry_02_122", northSprite = "carpentry_02_122" },
    generator = { sprite = "appliances_misc_01_0", northSprite = "appliances_misc_01_0" },
    counter = { sprite = "furniture_counters_01_0", northSprite = "furniture_counters_01_0" },
    sink = { sprite = "fixtures_sinks_01_0", northSprite = "fixtures_sinks_01_0" },
}

C.LIGHT_PROPERTIES = {
    -- `attachedW` is an IsoFlagType bit, not a string PropertyContainer key.
    -- The server resolves this name through IsoFlagType before calling
    -- PropertyContainer:has; the light type is an IsoObjectType enum checked
    -- against the sprite itself.  The remaining entries below are ordinary
    -- string properties read with PropertyContainer:has/get.  BuildCraft's
    -- custom switch tile has no Facing key: its attachedW flag is the
    -- authoritative west-wall orientation.
    attachedFlag = "attachedW",
    objectType = "lightswitch",
    movable = "IsMoveAble",
    radius = "LightRadius",
    red = "lightR",
    green = "lightG",
    blue = "lightB",
    customName = "CustomName",
    customNameValue = "Switch",
    groupName = "GroupName",
    groupNameValue = "Light",
    moveType = "MoveType",
    moveTypeValue = "WallObject",
}

-- Flat aliases are the server implementation's deliberately small input
-- surface.  Keep them derived from SPRITES so the layout cannot silently use
-- a different tile vocabulary.
C.WOOD_FLOOR_SPRITE = C.SPRITES.woodFloor.sprite
C.WALL_WEST_SPRITE = C.SPRITES.wall.sprite
C.WALL_NORTH_SPRITE = C.SPRITES.wall.northSprite
C.WALL_NW_SPRITE = C.SPRITES.wallNW.sprite
C.WALL_SE_SPRITE = C.SPRITES.wallSE.sprite
C.ROOF_FLOOR_SPRITE = C.SPRITES.roofFloor.sprite
C.LIGHT_SPRITE = C.SPRITES.wallLamp.sprite
C.RAIN_COLLECTOR_SPRITE = C.SPRITES.rainCollector.sprite
C.RAIN_BARREL_SPRITE = C.RAIN_COLLECTOR_SPRITE
C.GENERATOR_SPRITE = C.SPRITES.generator.sprite
C.COUNTER_SPRITE = C.SPRITES.counter.sprite
C.SINK_SPRITE = C.SPRITES.sink.sprite

-- Object/item type names are hints for the server implementation.  They are
-- kept here to make the eventual IsoRoom/object implementation replaceable
-- without changing the menu or layout contract.
C.TYPES = {
    generator = "Base.Generator",
    counter = "Base.Counter",
    sink = "Base.Sink",
    rainCollector = "Base.RainCollector",
}

-- Technical-test initial state requested by the design brief.
C.GENERATOR_INITIAL_FUEL = 10.0 -- B42.20 max fuel; this is 100% full.
C.GENERATOR_INITIAL_ON = true
-- Capacity differs between small and large vanilla collectors in Build 42;
-- the server resolves the generated object's FluidContainer capacity before
-- setting waterMax/waterAmount.  B42.20's carpentry_02_122 large collector is
-- 600; this value is only the defensive fallback when the runtime component
-- cannot be queried (it is not a replacement for the component's capacity).
C.RAIN_COLLECTOR_INITIAL_WATER = "full"
C.RAIN_COLLECTOR_INITIAL_WATER_RATIO = 1.0
C.RAIN_COLLECTOR_CAPACITY_FALLBACK = 600
C.RAIN_COLLECTOR_CAPACITY = C.RAIN_COLLECTOR_CAPACITY_FALLBACK
C.LAMP_INITIAL_ON = true

return C
