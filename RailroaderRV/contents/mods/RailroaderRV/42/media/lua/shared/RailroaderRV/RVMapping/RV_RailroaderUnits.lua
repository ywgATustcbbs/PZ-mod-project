-- Stable Railroader unit lookup for RV interactions.
--
-- Railroader's public unit views are resolved by the stable animal ID. RV keeps
-- only the small view it consumes; no RR records or reused API tables escape.

local API = require "Railroader/RR_API"

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderUnits = RailroaderRV.RailroaderUnits or {}

local Units = RailroaderRV.RailroaderUnits

local function sameId(first, second)
    local a, b = tonumber(first), tonumber(second)
    return a ~= nil and b ~= nil and a == b
end

local function idKey(id)
    local number = tonumber(id)
    return number ~= nil and tostring(number) or nil
end

local function findPublicLocomotive(id, views)
    for _, view in ipairs(views) do
        if sameId(view.id, id) then return view end
    end
    return nil
end

local function copyLocomotiveView(view)
    return {
        id = view.id,
        kind = "loco",
        isLocomotive = true,
        locomotiveId = view.id,
        x = view.x,
        y = view.y,
        z = view.z,
        dirX = view.dirX,
        dirY = view.dirY,
        speed = view.speed,
    }
end

local function copyUnitView(unit, ownerView)
    local isCut = unit.isCut == true
    local locomotiveId
    local speed
    if isCut then
        speed = 0
    else
        locomotiveId = unit.trainId
        speed = ownerView.speed
    end
    return {
        id = unit.id,
        kind = unit.kind,
        isLocomotive = unit.isLoco == true,
        isCut = isCut,
        locomotiveId = locomotiveId,
        speed = speed,
        x = unit.x,
        y = unit.y,
        z = unit.z,
        dirX = unit.dirX,
        dirY = unit.dirY,
        halfLengthTiles = unit.halfLength,
        halfWidthTiles = unit.halfWidth,
    }
end

local function resolve(unitId, apiViews)
    local wanted = tonumber(unitId)
    if wanted == nil then return nil, "unknown" end

    apiViews = apiViews or API.trains({})
    local publicView = findPublicLocomotive(wanted, apiViews)
    if publicView then return copyLocomotiveView(publicView) end

    local trainId, index, isCut = API.unitOf(wanted)
    if trainId == nil then
        return nil, index
    end

    local unitViews, reason = API.units(trainId, {})
    if not unitViews then return nil, reason end
    local unit = unitViews[index]
    if unit.isLoco then return nil, "unavailable-locomotive" end

    local ownerView
    if not isCut then
        ownerView = findPublicLocomotive(trainId, apiViews)
        if not ownerView then return nil, "unavailable-locomotive" end
    end
    return copyUnitView(unit, ownerView)
end

function Units.find(unitId)
    return resolve(unitId)
end

local function appendUnit(out, seen, unit, ownerView)
    local key = idKey(unit.id)
    if key and not seen[key] then
        seen[key] = true
        out[#out + 1] = copyUnitView(unit, ownerView)
    end
end

local function appendConsistUnits(out, seen, consistId, ownerView)
    local unitViews, reason = API.units(consistId, {})
    if not unitViews then return nil, reason end
    for _, unit in ipairs(unitViews) do
        if not unit.isLoco then
            appendUnit(out, seen, unit, ownerView)
        end
    end
    return true
end

function Units.list()
    if API.mode() == "none" then return nil, "unavailable" end

    local apiViews = API.trains({})
    local out, seen = {}, {}
    for _, view in ipairs(apiViews) do
        local key = idKey(view.id)
        if key then
            seen[key] = true
            out[#out + 1] = copyLocomotiveView(view)
        end
    end

    for _, view in ipairs(apiViews) do
        local ok, reason = appendConsistUnits(
            out, seen, view.id, view)
        if not ok then return nil, reason end
    end

    for _, cut in ipairs(API.cuts({})) do
        local ok, reason = appendConsistUnits(
            out, seen, cut.id)
        if not ok then return nil, reason end
    end
    return out
end

local function boxDistance(view, x, y)
    local dx, dy = x - view.x, y - view.y
    local along = dx * view.dirX + dy * view.dirY
    local across = dx * -view.dirY + dy * view.dirX
    local excessLength = math.max(math.abs(along) - view.halfLengthTiles, 0)
    local excessWidth = math.max(math.abs(across) - view.halfWidthTiles, 0)
    return math.sqrt(excessLength * excessLength + excessWidth * excessWidth)
end

function Units.geometry(unitView, x, y)
    local current, reason = resolve(unitView.id)
    if not current then return nil, reason end

    if current.isLocomotive then
        local apiGeometry, why = API.locomotiveGeometry(
            current.id, x, y, { seatPositions = {} })
        if not apiGeometry then return nil, why end
        return {
            hullDistanceTiles = apiGeometry.hullDistanceTiles,
            mountReachTiles = apiGeometry.mountReachTiles,
            x = current.x,
            y = current.y,
            z = current.z,
            dirX = current.dirX,
            dirY = current.dirY,
        }
    end

    if current.x == nil or current.y == nil
            or current.dirX == nil or current.dirY == nil then
        return nil, "nopose"
    end

    local geometry = {
        x = current.x,
        y = current.y,
        z = current.z,
        dirX = current.dirX,
        dirY = current.dirY,
        halfLengthTiles = current.halfLengthTiles,
        halfWidthTiles = current.halfWidthTiles,
    }
    local pointX, pointY = tonumber(x), tonumber(y)
    if pointX ~= nil and pointY ~= nil then
        geometry.hullDistanceTiles = boxDistance(current, pointX, pointY)
    end
    return geometry
end

return Units
