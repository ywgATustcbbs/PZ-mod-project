-- RailroaderRVTest shared constants.
--
-- This module has no dependency on a legacy Railroader adapter.  BuildingCraft
-- and Railroader are the runtime dependencies for the light/locomotive paths.
-- The server side owns all world mutation; these values are shared only so
-- that the client request and server layout use the same contract.

RailroaderRV = RailroaderRV or {}
RailroaderRV.Constants = RailroaderRV.Constants or {}

local C = RailroaderRV.Constants

function C.finiteNumber(value)
    local valueType = type(value)
    local number
    if valueType == "number" then
        number = value
    elseif valueType == "string" then
        number = tonumber(value)
    elseif value ~= nil then
        -- Network table numbers may be Java wrappers, so coerce them through
        -- guarded arithmetic instead of tonumber's string overload.
        local converted, numeric = pcall(function() return value + 0 end)
        if converted and type(numeric) == "number" then number = numeric end
    end
    if type(number) ~= "number" or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

function C.finiteInteger(value)
    local number = C.finiteNumber(value)
    if number == nil or math.floor(number) ~= number then return nil end
    return number
end

C.MOD_ID = "RailroaderRVTest"
C.COMMAND_GENERATE = "Generate"
C.COMMAND_FINAL_RELOCATE = "FinalRelocate"
C.COMMAND_FINAL_RELOCATE_ACK = "FinalRelocateAck"
C.COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
C.COMMAND_RV_ENTER = "EnterRV"
C.COMMAND_RV_EXIT = "ExitRV"
C.COMMAND_RV_TELEPORT = "RVTeleport"
C.COMMAND_RV_BOUNDARY_CORRECTION = "RVBoundaryCorrection"
C.COMMAND_RV_BITMAP = "RVBitmap"
C.COMMAND_RV_BITMAP_CLEAR = "RVBitmapClear"
C.COMMAND_RV_UTILITY = "RVUtility"
C.COMMAND_RV_UTILITY_ACK = "RVUtilityAck"
C.COMMAND_RV_UTILITY_SNAPSHOT = "RVUtilitySnapshot"
C.COMMAND_RV_UTILITY_MAPPING = "RVUtilityMapping"
C.RV_MAP_KEY = "RailroaderRVTest.TrainMap"
C.MANIFEST_KEY = "RailroaderRVTest.Manifest"
C.TECH_VERSION = "0.3.0-tech"
C.MANIFEST_SCHEMA_VERSION = 2
C.MAP_SCHEMA_VERSION = 2
C.RV_RECORD_SCHEMA_VERSION = 2
C.RV_RELATION_SCHEMA_VERSION = 2
C.BOUNDARY_SCHEMA_VERSION = 2
C.LAYOUT_SCHEMA_VERSION = 5
C.UTILITY_STORE_SCHEMA_VERSION = 3
C.UTILITY_WATER_SCHEMA_VERSION = 4
C.UTILITY_POWER_SCHEMA_VERSION = 2
C.UTILITY_WATER_CAPACITY = 1000.0
C.SAVE_REBUILD_REQUIRED = "RailroaderRVTest: 开发版本存档不兼容，请删除该测试存档并重建 (delete this test save and rebuild it)"

-- The current test button always targets this server-selected destination.
-- Clients never send or choose these coordinates.
C.TELEPORT_X = 20050
C.TELEPORT_Y = 2050
C.TELEPORT_Z = 0

-- The generated room is an RV destination, not a Railroader room.  The
-- persistent map uses a half-open 100x100 XY region so that the reverse lookup
-- is based on the passenger's coordinate and never on an IsoRoom/id value.
C.RV_REGION_SIZE = 100
C.RV_MANAGED_WIDTH = 100
C.RV_MANAGED_HEIGHT = 100
C.BITMAP_SCHEMA_VERSION = 2
C.BITMAP_VERSION = 2
C.RV_REGION_MIN_OFFSET_X = -50
C.RV_REGION_MIN_OFFSET_Y = -50
C.RV_MANAGED_MIN_Z_OFFSET = 0
-- maxZ is half-open.  The current generated layout owns the base and roof
-- layers; future layouts may add more layers without changing XY semantics.
C.RV_MANAGED_MAX_Z_OFFSET = 2
C.RV_MOUNT_REACH = 2.0
C.RV_STOPPED_SPEED = 0.05
C.RV_MAX_PASSENGERS = 5

-- The generation/management footprint uses the same half-open 100 x 100 XY
-- contract as the boundary bitmap.  maxX/maxY are exclusive.
C.CLEAR_MIN_OFFSET_X = -50
C.CLEAR_MAX_OFFSET_X = C.CLEAR_MIN_OFFSET_X + C.RV_MANAGED_WIDTH
C.CLEAR_MIN_OFFSET_Y = -50
C.CLEAR_MAX_OFFSET_Y = C.CLEAR_MIN_OFFSET_Y + C.RV_MANAGED_HEIGHT
C.BOUNDARY_TICK_INTERVAL = 1
C.BOUNDARY_CLEANUP_RESCAN_TICKS = 600
C.BOUNDARY_RECOVERY_COOLDOWN_TICKS = 8
C.BOUNDARY_TRANSITION_TIMEOUT_TICKS = 120
C.BOUNDARY_SNAPSHOT_TIMEOUT_TICKS = 120
C.BOUNDARY_SNAPSHOT_REFRESH_TICKS = 60

-- Process-local relocation sentinel contract.  Both temporary destinations are
-- derived from the current RV managed-bitmap center; these values describe only
-- the staging layer and the roof refresh center-offset vector.
C.RELOCATION_SENTINEL_Z = -15
C.ROOF_REPAIR_REMOTE_OFFSET_X = 18000
C.ROOF_REPAIR_REMOTE_OFFSET_Y = 0
C.ROOF_REPAIR_REMOTE_OFFSET_Z = 15
C.RELOCATION_SENTINEL_INTERVAL_TICKS = 5
C.RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS = 10

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

-- Water uses a deterministic, non-visible work object.  It is deliberately
-- outside every fixture's 3x3/z+1 search neighborhood; it is a mirror of the
-- canonicalTank record, never a second balance or a global water provider.
C.UTILITY_TANK_OFFSET = { x = 4, y = 0, z = 0 }
C.UTILITY_PROXY_Z_OFFSET = 1
C.UTILITY_ROLE_TANK = "rv_hidden_usage_tank"
C.UTILITY_ROLE_PROXY = "rv_hidden_proxy"
C.UTILITY_HIDDEN_OBJECT_CLASS = "IsoThumpable"
C.UTILITY_HIDDEN_SPRITE_KEY = "RailroaderRVTest_utility_hidden"
-- IsoSpriteManager:AddSprite(name, id) is required so the server's complete
-- add packet resolves to the same isolated blueprint sprite in the client
-- intMap. Keep the id outside normal tileset ranges and fail closed on any
-- collision rather than mutating an unrelated sprite.
C.UTILITY_HIDDEN_SPRITE_ID = 2147000000
C.UTILITY_AUTO_REFILL_STATE = "DISABLED"
C.UTILITY_AUTO_REFILL_PROVIDER = ""
C.UTILITY_AUTO_REFILL_CHANNEL = ""

-- Direction-independent object placement contract.  Layout.lua resolves
-- these offsets into absolute coordinates for the server worker.
C.LAMP_OFFSET = { x = -2, y = 0, z = 0 }
C.COUNTER_OFFSET = { x = 1, y = 0, z = 0 }
C.SINK_OFFSET = { x = 1, y = 0, z = 0 }
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
    -- The utility objects are rendered off.  Their isolated sprite is a
    -- registered blueprint and must never alias ordinary furniture.
    utilityHidden = { sprite = C.UTILITY_HIDDEN_SPRITE_KEY, northSprite = C.UTILITY_HIDDEN_SPRITE_KEY },
    utilityProxy = { sprite = C.UTILITY_HIDDEN_SPRITE_KEY, northSprite = C.UTILITY_HIDDEN_SPRITE_KEY },
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

-- Technical-test initial state requested by the design brief.
C.GENERATOR_INITIAL_FUEL = 10.0 -- B42.20 max fuel; this is 100% full.

return C
