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
C.COMMAND_DUMP_TEMPLATE_CAPTURE = "DumpTemplateCapture"
C.COMMAND_FINAL_RELOCATE = "FinalRelocate"
C.COMMAND_FINAL_RELOCATE_ACK = "FinalRelocateAck"
C.COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
C.COMMAND_RV_ENTER = "EnterRV"
C.COMMAND_RV_EXIT = "ExitRV"
C.COMMAND_RV_TELEPORT = "RVTeleport"
C.COMMAND_RV_BOUNDARY_CORRECTION = "RVBoundaryCorrection"
C.COMMAND_RV_UTILITY = "RVUtility"
C.COMMAND_RV_UTILITY_ACK = "RVUtilityAck"
C.COMMAND_RV_UTILITY_SNAPSHOT = "RVUtilitySnapshot"
C.COMMAND_RV_UTILITY_MAPPING = "RVUtilityMapping"
C.RV_MAP_KEY = "RailroaderRVTest.TrainMap"
C.TECH_VERSION = "0.4.0-tech"
C.SAVE_SCHEMA_VERSION = 9
C.CAPTURED_TEMPLATE_VERSION = 11
C.INVALID_RV_DATA = "RailroaderRVTest: RV data is invalid; delete this development test save and rebuild it"

-- The current test button always targets this server-selected destination.
-- Clients never send or choose these coordinates.
C.TELEPORT_X = 20050
C.TELEPORT_Y = 2050
C.TELEPORT_Z = 0

-- The generated room is an RV destination, not a Railroader room.  The
-- persistent map uses a half-open 100x100 XY region so that the reverse lookup
-- is based on the passenger's coordinate and never on an IsoRoom/id value.
C.RV_REGION_SIZE = 100
C.RV_REGION_SLOT_ROWS = 5
C.RV_REGION_SLOT_COLUMNS = 20
C.RV_REGION_SLOT_COUNT = C.RV_REGION_SLOT_ROWS * C.RV_REGION_SLOT_COLUMNS
-- Mapping identifies the RV's full supported world height. Construction's
-- selected clear/managed bounds remain independently limited by the layout.
C.RV_IDENTITY_MIN_Z = -32
C.RV_IDENTITY_MAX_Z = 32
C.RV_REGION_MIN_OFFSET_X = -50
C.RV_REGION_MIN_OFFSET_Y = -50
C.RV_MANAGED_MIN_Z_OFFSET = 0
-- maxZ is half-open.  The current generated layout owns the base and roof
-- layers; future layouts may add more layers without changing XY semantics.
C.RV_MANAGED_MAX_Z_OFFSET = 2
C.RV_MOUNT_REACH = 2.0
C.RV_STOPPED_SPEED = 0.05
C.RV_MAX_PASSENGERS = 5

-- The generation/management footprint uses the allocated half-open RV region.
C.BOUNDARY_TRANSITION_TIMEOUT_TICKS = 120
C.BOUNDARY_SNAPSHOT_TIMEOUT_TICKS = 120
C.BOUNDARY_SNAPSHOT_REFRESH_TICKS = 60

-- Process-local relocation sentinel contract.  Both temporary destinations are
-- derived from the current RV managed-region center; these values describe only
-- the staging layer and the roof refresh center-offset vector.
C.RELOCATION_SENTINEL_Z = -15
C.ROOF_REFRESH_REMOTE_OFFSET_X = 18000
C.ROOF_REFRESH_REMOTE_OFFSET_Y = 0
C.ROOF_REFRESH_REMOTE_OFFSET_Z = 15
C.RELOCATION_SENTINEL_INTERVAL_TICKS = 5
C.RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS = 10

C.TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS = 10

-- The isolated sprite is used only for captured hidden blockers and the RV
-- generator. Water connections use existing native sink objects.
C.UTILITY_HIDDEN_SPRITE_KEY = "RailroaderRVTest_utility_hidden"
-- IsoSpriteManager:AddSprite(name, id) is required so the server's complete
-- add packet resolves to the same isolated blueprint sprite in the client
-- intMap. Keep the id outside normal tileset ranges and fail closed on any
-- collision rather than mutating an unrelated sprite.
C.UTILITY_HIDDEN_SPRITE_ID = 2147000000
-- The only extra gameplay object retained beside the captured template is the
-- generator. It shares a captured roof square above the former floor-only
-- generator point, keeping the active machine outside the enclosed interior.
C.GENERATOR_OFFSET = { x = 0, y = 3, z = 1 }

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
    -- Captured blockers and the generator use an isolated sprite that must
    -- never alias ordinary furniture.
    utilityHidden = { sprite = C.UTILITY_HIDDEN_SPRITE_KEY, northSprite = C.UTILITY_HIDDEN_SPRITE_KEY },
    generator = { sprite = "appliances_misc_01_0", northSprite = "appliances_misc_01_0" },
}

-- Technical-test initial state requested by the design brief.
C.GENERATOR_INITIAL_FUEL = 10.0 -- B42.20 max fuel; this is 100% full.

return C
