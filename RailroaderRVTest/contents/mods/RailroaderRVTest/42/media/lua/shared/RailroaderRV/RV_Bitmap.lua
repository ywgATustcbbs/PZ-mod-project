-- Canonical RV-local geometry.
--
-- A bitmap is deliberately independent from the world and from any IsoObject.
-- The server and client can therefore use the same cell/segment predicates,
-- while the server remains the only authority that changes the world.  The
-- in-memory bitset is a packed byte string (one bit per cell); persistence and
-- network snapshots use hexadecimal text so a NUL byte cannot be interpreted
-- as a truncated ModData/command value.

require "RailroaderRV/RV_Constants"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Bitmap = RailroaderRV.Bitmap or {}

local Bitmap = RailroaderRV.Bitmap
local C = RailroaderRV.Constants

-- Bitmaps are immutable after generation/decoding. Cache the walk geometry
-- outside the persisted bitmap so this never changes its wire schema.
local walkBoundsCache = setmetatable({}, { __mode = "k" })
local layerBits

Bitmap.SCHEMA_VERSION = C.BITMAP_SCHEMA_VERSION
Bitmap.DEFAULT_WIDTH = C.RV_MANAGED_WIDTH
Bitmap.DEFAULT_HEIGHT = C.RV_MANAGED_HEIGHT

local function finiteNumber(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value ~= nil then
        local ok, number = pcall(function() return value + 0 end)
        if ok and type(number) == "number" then return number end
    end
    return nil
end

local function integer(value)
    local number = finiteNumber(value)
    if number == nil or math.floor(number) ~= number then return nil end
    return number
end

local function exactKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed, count = {}, 0
    for i = 1, #expected do allowed[expected[i]] = true end
    for key in pairs(value) do
        if not allowed[key] then return false end
        count = count + 1
    end
    return count == #expected
end

Bitmap.hasExactKeys = exactKeys

local function dimensions(width, height)
    width = integer(width) or Bitmap.DEFAULT_WIDTH
    height = integer(height) or Bitmap.DEFAULT_HEIGHT
    if width < 1 or height < 1 then return nil end
    return width, height, math.ceil((width * height) / 8)
end

local function byteLength(width, height)
    local _, _, bytes = dimensions(width, height)
    return bytes
end

local function bitIndex(width, x, y)
    return y * width + x
end

local function validIndex(width, height, index)
    return type(index) == "number" and index >= 0
        and index < width * height and math.floor(index) == index
end

local function byteAndMask(index)
    local byteIndex = math.floor(index / 8) + 1
    local bit = index - ((byteIndex - 1) * 8)
    return byteIndex, 2 ^ bit
end

local function rawGet(bits, index, width, height)
    if type(bits) ~= "string" or not validIndex(width, height, index) then
        return false
    end
    local byteIndex, mask = byteAndMask(index)
    local value = string.byte(bits, byteIndex)
    return value ~= nil and math.floor(value / mask) % 2 >= 1
end

local function rawSet(bits, index, enabled, width, height)
    if type(bits) ~= "string" or not validIndex(width, height, index) then
        return bits
    end
    local byteIndex, mask = byteAndMask(index)
    local value = string.byte(bits, byteIndex) or 0
    local hasBit = math.floor(value / mask) % 2 >= 1
    if enabled and not hasBit then value = value + mask end
    if not enabled and hasBit then value = value - mask end
    return string.sub(bits, 1, byteIndex - 1) .. string.char(value)
        .. string.sub(bits, byteIndex + 1)
end

function Bitmap.byteLength(width, height)
    return byteLength(width, height)
end

function Bitmap.newBitset(width, height, fill)
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    local bytes = byteLength(width, height)
    if not bytes then return nil end
    if fill == true then return string.rep(string.char(255), bytes) end
    return string.rep(string.char(0), bytes)
end

function Bitmap.get(bits, index, width, height)
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    return rawGet(bits, index, width, height)
end

function Bitmap.set(bits, index, enabled, width, height)
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    return rawSet(bits, index, enabled == true, width, height)
end

function Bitmap.index(scope, x, y)
    if type(scope) ~= "table" then return nil end
    local originX, originY = integer(scope.originX), integer(scope.originY)
    local width, height = integer(scope.width), integer(scope.height)
    if not originX or not originY or not width or not height then return nil end
    x, y = finiteNumber(x), finiteNumber(y)
    if x == nil or y == nil then return nil end
    x, y = math.floor(x) - originX, math.floor(y) - originY
    if x < 0 or x >= width or y < 0 or y >= height then return nil end
    return bitIndex(width, x, y), x, y
end

function Bitmap.cell(scope, x, y)
    local index, ix, iy = Bitmap.index(scope, x, y)
    if index == nil then return nil end
    return { index = index, x = ix, y = iy,
        worldX = integer(scope.originX) + ix,
        worldY = integer(scope.originY) + iy }
end

function Bitmap.containsScope(scope, x, y, z)
    if type(scope) ~= "table" then return false end
    local originX, originY = integer(scope.originX), integer(scope.originY)
    local width, height = integer(scope.width), integer(scope.height)
    local minZ, maxZ = integer(scope.minZ), integer(scope.maxZ)
    x, y, z = finiteNumber(x), finiteNumber(y), finiteNumber(z)
    if not originX or not originY or not width or not height
        or not minZ or not maxZ or not x or not y or not z then
        return false
    end
    return x >= originX and x < originX + width
        and y >= originY and y < originY + height
        and math.floor(z) >= minZ and math.floor(z) < maxZ
end

local function rowContains(bits, width, height, y, firstX, lastX)
    for x = firstX, lastX do
        if not rawGet(bits, bitIndex(width, x, y), width, height) then
            return false
        end
    end
    return true
end

-- Outer bounds reject empty space. Inner bounds are a verified all-walkable
-- rectangle; only cells in the irregular band need an individual bit lookup.
local function buildWalkBounds(bitmap, z)
    if type(bitmap) ~= "table" then return nil end
    z = integer(z)
    if z == nil then return nil end
    local cache = walkBoundsCache[bitmap]
    if not cache then cache = {}; walkBoundsCache[bitmap] = cache end
    if cache[z] ~= nil then return cache[z] or nil end
    local layer = Bitmap.layer(bitmap, z)
    local width, height = bitmap.width, bitmap.height
    local bits = layerBits(layer, "walkBits", width, height)
    if not bits then cache[z] = false; return nil end
    local minX, maxX, minY, maxY = width, -1, height, -1
    local bestX, bestY, bestWidth = nil, nil, 0
    for y = 0, height - 1 do
        local runStart = nil
        for x = 0, width do
            local active = x < width and rawGet(bits,
                bitIndex(width, x, y), width, height)
            if active then
                if runStart == nil then runStart = x end
                if x < minX then minX = x end
                if x > maxX then maxX = x end
                if y < minY then minY = y end
                if y > maxY then maxY = y end
            elseif runStart ~= nil then
                if x - runStart > bestWidth then
                    bestX, bestY, bestWidth = runStart, y, x - runStart
                end
                runStart = nil
            end
        end
    end
    if maxX < minX then cache[z] = false; return nil end
    local top, bottom = bestY, bestY
    while top > minY and rowContains(bits, width, height,
        top - 1, bestX, bestX + bestWidth - 1) do top = top - 1 end
    while bottom < maxY and rowContains(bits, width, height,
        bottom + 1, bestX, bestX + bestWidth - 1) do bottom = bottom + 1 end
    local originX, originY = bitmap.originX, bitmap.originY
    local bounds = {
        outer = { minX = originX + minX, maxX = originX + maxX + 1,
            minY = originY + minY, maxY = originY + maxY + 1 },
        inner = { minX = originX + bestX, maxX = originX + bestX + bestWidth,
            minY = originY + top, maxY = originY + bottom + 1 },
    }
    cache[z] = bounds
    return bounds
end

-- Call after a bitmap has been fully built or decoded. Tick-time queries only
-- read the prepared per-layer entries and never scan walk bits on first use.
function Bitmap.prepareWalkBounds(bitmap)
    if type(bitmap) ~= "table" then return false end
    local minZ, maxZ = integer(bitmap.minZ), integer(bitmap.maxZ)
    if minZ == nil or maxZ == nil or maxZ <= minZ then return false end
    for z = minZ, maxZ - 1 do buildWalkBounds(bitmap, z) end
    return true
end

function Bitmap.walkBounds(bitmap, z)
    if type(bitmap) ~= "table" then return nil end
    z = integer(z)
    if z == nil then return nil end
    local cache = walkBoundsCache[bitmap]
    return cache and (cache[z] or nil) or nil
end

function Bitmap.inAABB(box, x, y)
    return box ~= nil and x >= box.minX and x < box.maxX
        and y >= box.minY and y < box.maxY
end

function Bitmap.walkableFast(bitmap, x, y, z)
    if not Bitmap.containsScope(bitmap, x, y, z) then return false, false end
    local bounds = Bitmap.walkBounds(bitmap, math.floor(z))
    if not bounds or not Bitmap.inAABB(bounds.outer, x, y) then
        return false, false
    end
    if Bitmap.inAABB(bounds.inner, x, y) then return true, true end
    return Bitmap.isActive(bitmap, x, y, z), false
end

function Bitmap.makeScope(originX, originY, minZ, maxZ, width, height)
    originX, originY = integer(originX), integer(originY)
    minZ, maxZ = integer(minZ), integer(maxZ)
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    if not originX or not originY or not minZ or not maxZ
        or maxZ <= minZ or not dimensions(width, height) then
        return nil
    end
    return {
        originX = originX, originY = originY,
        width = width, height = height,
        minZ = minZ, maxZ = maxZ,
    }
end

function Bitmap.newLayer(width, height, walkFill, buildFill)
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    return {
        walkBits = Bitmap.newBitset(width, height, walkFill == true),
        buildBits = Bitmap.newBitset(width, height, buildFill == true),
        encoding = "bytes",
    }
end

function Bitmap.layer(bitmap, z)
    if type(bitmap) ~= "table" or type(bitmap.layers) ~= "table" then
        return nil
    end
    z = integer(z)
    if z == nil then return nil end
    return bitmap.layers[z] or bitmap.layers[tostring(z)]
end

layerBits = function(layer, field, width, height)
    if type(layer) ~= "table" then return nil end
    local bits = layer[field]
    if type(bits) ~= "string" then return nil end
    if #bits ~= byteLength(width, height) then return nil end
    return bits
end

function Bitmap.isActive(bitmap, x, y, z)
    if type(bitmap) ~= "table" or not Bitmap.containsScope(bitmap, x, y, z) then
        return false
    end
    local layer = Bitmap.layer(bitmap, math.floor(z))
    local bits = layerBits(layer, "walkBits", bitmap.width, bitmap.height)
    local index = bits and Bitmap.index(bitmap, x, y)
    return index ~= nil and rawGet(bits, index, bitmap.width, bitmap.height)
end

function Bitmap.isBuildable(bitmap, x, y, z)
    if type(bitmap) ~= "table" or not Bitmap.containsScope(bitmap, x, y, z) then
        return false
    end
    local layer = Bitmap.layer(bitmap, math.floor(z))
    local bits = layerBits(layer, "buildBits", bitmap.width, bitmap.height)
    local index = bits and Bitmap.index(bitmap, x, y)
    return index ~= nil and rawGet(bits, index, bitmap.width, bitmap.height)
end

function Bitmap.setCell(layer, x, y, enabled, width, height, field)
    if type(layer) ~= "table" then return false end
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    field = field == "build" and "buildBits" or "walkBits"
    local ix, iy = integer(x), integer(y)
    if not ix or not iy or ix < 0 or ix >= width or iy < 0 or iy >= height then
        return false
    end
    local bits = layer[field]
    if type(bits) ~= "string" or #bits ~= byteLength(width, height) then
        bits = Bitmap.newBitset(width, height)
    end
    layer[field] = rawSet(bits, bitIndex(width, ix, iy), enabled == true,
        width, height)
    return true
end

function Bitmap.toHex(bits)
    if type(bits) ~= "string" then return nil end
    local result = {}
    for i = 1, #bits do
        local value = string.byte(bits, i) or 0
        local high = math.floor(value / 16)
        local low = value - high * 16
        result[#result + 1] = string.format("%x%x", high, low)
    end
    return table.concat(result)
end

function Bitmap.fromHex(encoded, width, height)
    if type(encoded) ~= "string" or #encoded % 2 ~= 0 then return nil end
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    if #encoded ~= byteLength(width, height) * 2 then return nil end
    local result = {}
    for i = 1, #encoded, 2 do
        local pair = string.sub(encoded, i, i + 1)
        local value = tonumber(pair, 16)
        if value == nil then return nil end
        result[#result + 1] = string.char(value)
    end
    return table.concat(result)
end

function Bitmap.encodeLayer(layer, width, height)
    if type(layer) ~= "table" then return nil end
    if layer.encoding ~= "bytes" then return nil end
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    local walkBits = layerBits(layer, "walkBits", width, height)
    local buildBits = layerBits(layer, "buildBits", width, height)
    if not walkBits or not buildBits then return nil end
    return { walkBits = Bitmap.toHex(walkBits), buildBits = Bitmap.toHex(buildBits),
        encoding = "hex" }
end

function Bitmap.decodeLayer(layer, width, height)
    if type(layer) ~= "table" then return nil end
    if layer.encoding ~= "hex" then return nil end
    width, height = integer(width) or Bitmap.DEFAULT_WIDTH,
        integer(height) or Bitmap.DEFAULT_HEIGHT
    local walkBits = layer.walkBits
    local buildBits = layer.buildBits
    walkBits = Bitmap.fromHex(walkBits, width, height)
    buildBits = Bitmap.fromHex(buildBits, width, height)
    if not walkBits or not buildBits then return nil end
    return { walkBits = walkBits, buildBits = buildBits, encoding = "bytes" }
end

function Bitmap.encode(bitmap)
    if type(bitmap) ~= "table" or not Bitmap.validate(bitmap, false) then
        return nil
    end
    Bitmap.prepareWalkBounds(bitmap)
    local result = {
        schemaVersion = bitmap.schemaVersion,
        bitmapVersion = bitmap.bitmapVersion,
        originX = bitmap.originX, originY = bitmap.originY,
        width = bitmap.width, height = bitmap.height,
        minZ = bitmap.minZ, maxZ = bitmap.maxZ,
        layers = {}, encoding = "hex",
    }
    for z = bitmap.minZ, bitmap.maxZ - 1 do
        local layer = Bitmap.encodeLayer(Bitmap.layer(bitmap, z),
            bitmap.width, bitmap.height)
        if not layer then return nil end
        result.layers[z] = layer
    end
    return result
end

function Bitmap.decode(encoded)
    if type(encoded) ~= "table" then return nil end
    if not exactKeys(encoded, { "schemaVersion", "bitmapVersion", "originX",
        "originY", "width", "height", "minZ", "maxZ", "layers",
        "encoding" }) then return nil end
    if encoded.version ~= nil then return nil end
    if encoded.encoding ~= "hex" then return nil end
    local schemaVersion = integer(encoded.schemaVersion)
    if schemaVersion ~= Bitmap.SCHEMA_VERSION then return nil end
    local scope = Bitmap.makeScope(encoded.originX, encoded.originY,
        encoded.minZ, encoded.maxZ, encoded.width, encoded.height)
    if not scope then return nil end
    local bitmapVersion = integer(encoded.bitmapVersion)
    if bitmapVersion ~= C.BITMAP_VERSION then return nil end
    local result = {
        schemaVersion = schemaVersion,
        bitmapVersion = bitmapVersion,
        originX = scope.originX, originY = scope.originY,
        width = scope.width, height = scope.height,
        minZ = scope.minZ, maxZ = scope.maxZ,
        layers = {}, encoding = "bytes",
    }
    for z = scope.minZ, scope.maxZ - 1 do
        local encodedLayer = Bitmap.layer(encoded, z)
        if not exactKeys(encodedLayer, { "walkBits", "buildBits", "encoding" }) then
            return nil
        end
        local layer = Bitmap.decodeLayer(encodedLayer,
            scope.width, scope.height)
        if not layer then return nil end
        result.layers[z] = layer
    end
    Bitmap.prepareWalkBounds(result)
    return result
end

function Bitmap.validate(bitmap, allowEncoded)
    if type(bitmap) ~= "table" then return false end
    local expectedKeys = { "schemaVersion", "bitmapVersion", "originX",
        "originY", "width", "height", "minZ", "maxZ", "layers",
        "encoding" }
    if not exactKeys(bitmap, expectedKeys) then return false end
    local schema = integer(bitmap.schemaVersion)
    local width, height = integer(bitmap.width), integer(bitmap.height)
    local originX, originY = integer(bitmap.originX), integer(bitmap.originY)
    local minZ, maxZ = integer(bitmap.minZ), integer(bitmap.maxZ)
    local bitmapVersion = integer(bitmap.bitmapVersion)
    if schema ~= Bitmap.SCHEMA_VERSION or not width or not height
        or width ~= Bitmap.DEFAULT_WIDTH or height ~= Bitmap.DEFAULT_HEIGHT
        or not originX or not originY or not minZ or not maxZ or maxZ <= minZ
        or bitmapVersion ~= C.BITMAP_VERSION
        or type(bitmap.layers) ~= "table"
        or (allowEncoded and bitmap.encoding ~= "hex")
        or (not allowEncoded and bitmap.encoding ~= "bytes") then
        return false
    end
    local layerCount = 0
    for key in pairs(bitmap.layers) do
        if type(key) ~= "number" or not finiteNumber(key)
            or math.floor(key) ~= key or key < minZ or key >= maxZ then
            return false
        end
        layerCount = layerCount + 1
    end
    if layerCount ~= maxZ - minZ then return false end
    for z = minZ, maxZ - 1 do
        local layer = Bitmap.layer(bitmap, z)
        if not exactKeys(layer, { "walkBits", "buildBits", "encoding" }) then
            return false
        end
        local expected = byteLength(width, height)
        local walk, build = layer.walkBits, layer.buildBits
        if allowEncoded and layer.encoding == "hex" then
            if type(walk) ~= "string" or #walk ~= expected * 2
                or type(build) ~= "string" or #build ~= expected * 2 then
                return false
            end
            if not Bitmap.fromHex(walk, width, height)
                or not Bitmap.fromHex(build, width, height) then
                return false
            end
        elseif not allowEncoded and layer.encoding == "bytes"
            and type(walk) == "string" and #walk == expected
            and type(build) == "string" and #build == expected then
            -- Current in-memory representation.
        else
            return false
        end
    end
    return true
end

-- Return a deterministic nearest cell center.  This search is intentionally
-- finite and RV-local; it never searches a world-wide fallback coordinate.
function Bitmap.nearestActive(bitmap, x, y, z)
    if type(bitmap) ~= "table" then return nil end
    local width, height = integer(bitmap.width), integer(bitmap.height)
    local originX, originY = integer(bitmap.originX), integer(bitmap.originY)
    local minZ, maxZ = integer(bitmap.minZ), integer(bitmap.maxZ)
    z = integer(z)
    if not width or not height or not originX or not originY or not z
        or not minZ or not maxZ then
        return nil
    end
    local startX = math.floor(finiteNumber(x) or originX) - originX
    local startY = math.floor(finiteNumber(y) or originY) - originY
    if startX < 0 then startX = 0 elseif startX >= width then startX = width - 1 end
    if startY < 0 then startY = 0 elseif startY >= height then startY = height - 1 end
    local function searchLayer(layerZ)
        local maxRadius = width + height
        for radius = 0, maxRadius do
            local minX, maxX = startX - radius, startX + radius
            local minY, maxY = startY - radius, startY + radius
            for ix = minX, maxX do
                local iy = minY
                if ix >= 0 and ix < width and iy >= 0 and iy < height
                    and Bitmap.isActive(bitmap, originX + ix, originY + iy, layerZ) then
                    return { x = originX + ix + 0.5,
                        y = originY + iy + 0.5, z = layerZ }
                end
                iy = maxY
                if maxY ~= minY and ix >= 0 and ix < width and iy >= 0 and iy < height
                    and Bitmap.isActive(bitmap, originX + ix, originY + iy, layerZ) then
                    return { x = originX + ix + 0.5,
                        y = originY + iy + 0.5, z = layerZ }
                end
            end
            for iy = minY + 1, maxY - 1 do
                local ix = minX
                if ix >= 0 and ix < width and iy >= 0 and iy < height
                    and Bitmap.isActive(bitmap, originX + ix, originY + iy, layerZ) then
                    return { x = originX + ix + 0.5,
                        y = originY + iy + 0.5, z = layerZ }
                end
                ix = maxX
                if maxX ~= minX and ix >= 0 and ix < width and iy >= 0 and iy < height
                    and Bitmap.isActive(bitmap, originX + ix, originY + iy, layerZ) then
                    return { x = originX + ix + 0.5,
                        y = originY + iy + 0.5, z = layerZ }
                end
            end
        end
        return nil
    end

    -- Prefer the player's current layer, then the nearest managed layer.  The
    -- vertical fallback matters after a desync/reconnect when no last-valid
    -- cache survived, while still remaining strictly inside this RV scope.
    local preferredZ = z
    if preferredZ < minZ then preferredZ = minZ end
    if preferredZ >= maxZ then preferredZ = maxZ - 1 end
    local found = searchLayer(preferredZ)
    if found then return found end
    for distance = 1, maxZ - minZ do
        local lower, upper = preferredZ - distance, preferredZ + distance
        if lower >= minZ then
            found = searchLayer(lower)
            if found then return found end
        end
        if upper < maxZ then
            found = searchLayer(upper)
            if found then return found end
        end
    end
    return nil
end

local function addTime(times, value)
    if value > 0 and value < 1 then times[#times + 1] = value end
end

local function sortUniqueTimes(times)
    table.sort(times)
    local result = { 0 }
    for i = 1, #times do
        local value = times[i]
        if value ~= 0 and value ~= 1
            and value ~= result[#result] then
            result[#result + 1] = value
        end
    end
    result[#result + 1] = 1
    return result
end

-- Supercover segment test.  Checking a small neighbourhood at every grid
-- boundary catches diagonal corner tunnelling and hole crossings; any
-- conservative extra cell is still inside the canonical bitmap and thus
-- cannot affect the world outside this RV.
function Bitmap.segmentValid(bitmap, from, to)
    if type(bitmap) ~= "table" or type(from) ~= "table" or type(to) ~= "table" then
        return false
    end
    local sx, sy, sz = finiteNumber(from.x), finiteNumber(from.y), finiteNumber(from.z)
    local ex, ey, ez = finiteNumber(to.x), finiteNumber(to.y), finiteNumber(to.z)
    if not sx or not sy or not sz or not ex or not ey or not ez then return false end
    if not Bitmap.containsScope(bitmap, sx, sy, sz)
        or not Bitmap.containsScope(bitmap, ex, ey, ez) then
        return false
    end
    local dx, dy, dz = ex - sx, ey - sy, ez - sz
    local times = {}
    local startCellX, endCellX = math.floor(sx), math.floor(ex)
    if dx > 0 then
        for boundary = startCellX + 1, endCellX do
            addTime(times, (boundary - sx) / dx)
        end
    elseif dx < 0 then
        for boundary = startCellX, endCellX + 1, -1 do
            addTime(times, (boundary - sx) / dx)
        end
    end
    local startCellY, endCellY = math.floor(sy), math.floor(ey)
    if dy > 0 then
        for boundary = startCellY + 1, endCellY do
            addTime(times, (boundary - sy) / dy)
        end
    elseif dy < 0 then
        for boundary = startCellY, endCellY + 1, -1 do
            addTime(times, (boundary - sy) / dy)
        end
    end
    if dz > 0 then
        for boundary = math.floor(sz) + 1, math.floor(ez) do
            addTime(times, (boundary - sz) / dz)
        end
    elseif dz < 0 then
        for boundary = math.floor(sz), math.floor(ez) + 1, -1 do
            addTime(times, (boundary - sz) / dz)
        end
    end
    local ordered = sortUniqueTimes(times)
    local epsilon = 0.000001
    for i = 1, #ordered do
        local t = ordered[i]
        local offsets = { -epsilon, 0, epsilon }
        for j = 1, #offsets do
            local tx = t + offsets[j]
            if tx >= 0 and tx <= 1 then
                for k = 1, #offsets do
                    local ty = t + offsets[k]
                    if ty >= 0 and ty <= 1 then
                        for l = 1, #offsets do
                            local tz = t + offsets[l]
                            if tz >= 0 and tz <= 1 then
                                local x = sx + dx * tx
                                local y = sy + dy * ty
                                local z = sz + dz * tz
                                if not Bitmap.isActive(bitmap, x, y, z) then
                                    return false, { x = math.floor(x),
                                        y = math.floor(y), z = math.floor(z) }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return true
end

function Bitmap.edgeKey(axis, x, y, z)
    axis = axis == "N" and "N" or axis == "W" and "W" or nil
    x, y, z = integer(x), integer(y), integer(z)
    if not axis or not x or not y or not z then return nil end
    return axis .. ":" .. tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

-- PZ stores only north/west edge ownership on a tile.  Express the other
-- two room sides through their adjacent host tile instead of treating an
-- inactive anchor cell as the owner: east is W(x+1,y,z), south is
-- N(x,y+1,z).  `x,y` name the active cell whose boundary is being described.
function Bitmap.edgeForSide(side, x, y, z)
    x, y, z = integer(x), integer(y), integer(z)
    if not x or not y or not z then return nil end
    if side == "north" or side == "N" then
        return Bitmap.edgeKey("N", x, y, z)
    elseif side == "west" or side == "W" then
        return Bitmap.edgeKey("W", x, y, z)
    elseif side == "east" or side == "E" then
        return Bitmap.edgeKey("W", x + 1, y, z)
    elseif side == "south" or side == "S" then
        return Bitmap.edgeKey("N", x, y + 1, z)
    end
    return nil
end

Bitmap.boundaryEdge = Bitmap.edgeForSide

return Bitmap
