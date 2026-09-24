-- RV_Server: GenerationBuild responsibilities.
return function(ctx)
local MANIFEST_KEY = ctx.MANIFEST_KEY
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local function safeErrorText(...) return ctx.safeErrorText(...) end
local ensureRoofSquare = ctx.ensureRoofSquare
local createFloor = ctx.createFloor
local createWall = ctx.createWall
local createLight = ctx.createLight
local createGenerator = ctx.createGenerator
local createFurniture = ctx.createFurniture

safeErrorText = function(err)
    local textOk, text = pcall(tostring, err)
    if not textOk or type(text) ~= "string" then
        text = "<error formatting failed>"
    end
    local debugTable = rawget(_G, "debug")
    if type(debugTable) == "table" and type(debugTable.traceback) == "function" then
        local traceOk, trace = pcall(debugTable.traceback, text, 3)
        if traceOk then
            local traceTextOk, traceText = pcall(tostring, trace)
            if traceTextOk and type(traceText) == "string" then
                return traceText
            end
        end
    end
    return text
end

local function setManifestState(manifest, state, reason)
    manifest.state = state
    manifest.updatedAt = math.floor(os.time())
    if reason then
        manifest.lastError = safeErrorText(reason)
    end
    if ModData and type(ModData.transmit) == "function" then
        pcall(ModData.transmit, MANIFEST_KEY)
    end
end

local function manifestTable()
    if not ModData or type(ModData.getOrCreate) ~= "function" then
        error("RailroaderRVTest: ModData.getOrCreate is unavailable")
    end
    local manifest = ModData.getOrCreate(MANIFEST_KEY)
    if type(manifest) ~= "table" then
        error("RailroaderRVTest: manifest is not a table")
    end
    return manifest
end

local function setGenerationPhase(manifest, generation, phase)
    if manifest then
        manifest.phase = phase
        manifest.phaseGeneration = generation
        manifest.phaseUpdatedAt = math.floor(os.time())
        if ModData and type(ModData.transmit) == "function" then
            pcall(ModData.transmit, MANIFEST_KEY)
        end
    end
    print("[RailroaderRVTest] generation=" .. tostring(generation)
        .. " phase=" .. tostring(phase))
end

local function recalcAndCheckStructure(cell, bounds)
    local seen = {}
    local checked = 0
    local function recalcAt(x, y, z)
            local square = ServerWorld.getSquare(cell, x, y, z)
        if not square then
            error("RailroaderRVTest: structure square is not loaded")
        end
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if not seen[key] then
            seen[key] = true
            ServerWorld.recalcSquare(square)
            checked = checked + 1
        end
        return square
    end

    -- Rebuild the lower-room and upper-floor neighbours before any entity
    -- object is placed.  This is the ordering used by the player-building
    -- scripts and makes roof/region probes observe the finished structure.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            recalcAt(x, y, bounds.z)
        end
    end
    for x = bounds.roofMinX, bounds.roofMaxX do
        for y = bounds.roofMinY, bounds.roofMaxY do
            local roofSquare = recalcAt(x, y, bounds.roofZ)
            local floorOk, floor = ServerUtil.invoke(roofSquare, "getFloor")
            if not floorOk or not floor then
                error("RailroaderRVTest: roof floor missing after structure recalc")
            end
        end
    end
    for i = 1, #(bounds.wallCoordinates or {}) do
        local entry = bounds.wallCoordinates[i]
        recalcAt(entry.x, entry.y, bounds.z)
    end

    -- B42.20 can report room/roof metadata only after the neighbour pass.  A
    -- nil room is expected in this technical phase (IsoRoom registration is
    -- deferred), but probing it here keeps the phase observable and ensures
    -- the methods themselves are safe on the generated squares.
        local probe = ServerWorld.getSquare(cell, bounds.roomMinX, bounds.roomMinY, bounds.z)
    if probe then
        ServerUtil.invoke(probe, "getRoom")
        ServerUtil.invoke(probe, "getRoomID")
        ServerUtil.invoke(probe, "getRoofHideBuilding")
    end
    return checked
end

local function clearGenerationArea(cell, bounds, generation, manifest)
    setGenerationPhase(manifest, generation, "CLEARING")
    -- Cleanup is intentionally limited to already-loaded squares.  The
    -- snapshot/removal path handles zombies, corpses, trees, vegetation,
    -- rocks, decorative objects, and floors while emitting server-authoritative
    -- removal packets for every object it removes.
    ServerSchema.walkBounds(cell, bounds, function(square)
        ServerWorld.clearSquare(square, nil)
    end)
end

local function buildGeneration(player, layout, bounds, generation, manifest)
    local cell = ServerWorld.getCellForPlayer(player)
    local sprites = Constants.SPRITES
    local woodSprite = sprites and sprites.woodFloor and sprites.woodFloor.sprite
    local northWallSprite = sprites and sprites.wall and sprites.wall.northSprite
    local westWallSprite = sprites and sprites.wall and sprites.wall.sprite
    local nwWallSprite = sprites and sprites.wallNW and sprites.wallNW.sprite
    local seWallSprite = sprites and sprites.wallSE and sprites.wallSE.sprite
    local roofFloorSprite = sprites and sprites.roofFloor and sprites.roofFloor.sprite
    local lightSprite = sprites and sprites.wallLamp and sprites.wallLamp.sprite
    local generatorSprite = sprites and sprites.generator and sprites.generator.sprite
    local counterSprite = sprites and sprites.counter and sprites.counter.sprite
    local sinkSprite = sprites and sprites.sink and sprites.sink.sprite
    if not woodSprite or not northWallSprite or not westWallSprite
        or not nwWallSprite or not seWallSprite
        or not roofFloorSprite or not lightSprite
        or not generatorSprite or not counterSprite or not sinkSprite then
        error("RailroaderRVTest: shared sprite contract is incomplete")
    end

    -- Every feature point is part of the current shared layout contract.
    local anchor = layout.anchor
    local anchorX = ServerUtil.requiredInteger(anchor.x, "layout anchor.x")
    local anchorY = ServerUtil.requiredInteger(anchor.y, "layout anchor.y")
    local anchorZ = ServerUtil.requiredInteger(anchor.z, "layout anchor.z")
    local tagContext = {
        rvId = manifest and manifest.rvId,
        bitmapVersion = manifest and manifest.bitmapVersion,
    }
    if tagContext.rvId == nil or tostring(tagContext.rvId) == ""
        or ServerUtil.toNumber(tagContext.bitmapVersion) == nil then
        error("RailroaderRVTest: generation boundary identity is incomplete")
    end
    local lightPoint = ServerUtil.copyPoint(layout.light, "layout.light")

    setGenerationPhase(manifest, generation, "WOOD_FLOOR")
    -- Interior floor: exactly 6x40, using the shared carpet sprite.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            local square = ServerWorld.getSquare(cell, x, y, bounds.z)
            if not square then
                error("RailroaderRVTest: interior square is not loaded")
            end
            createFloor(square, woodSprite, generation, "wood_floor", tagContext)
        end
    end

    setGenerationPhase(manifest, generation, "WALLS")
    -- Apply the explicit wall ring from the shared layout.  NW and SE are
    -- single corner strips; all other entries are directional straight walls.
    local wallCoordinates = bounds.wallCoordinates or {}
    if #wallCoordinates ~= 92 then
        error("RailroaderRVTest: wall layout must contain exactly 92 objects")
    end
    local coordinateKeys = {}
    local orientationKeys = {}
    local exactKeys = {}
    local orientationByCoordinate = {}
    local uniqueCoordinates = 0
    local northEdges, westEdges, corners = 0, 0, 0
    local nwKey = tostring(bounds.wallMinX) .. ":" .. tostring(bounds.wallMinY)
        .. ":" .. tostring(bounds.z)
    local seKey = tostring(bounds.wallMaxX) .. ":" .. tostring(bounds.wallMaxY)
        .. ":" .. tostring(bounds.z)
    for i = 1, #wallCoordinates do
        local entry = wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean" then
            error("RailroaderRVTest: malformed wall entry at index " .. tostring(i))
        end
        local coordinateKey = tostring(entry.x) .. ":" .. tostring(entry.y)
            .. ":" .. tostring(entry.z)
        local orientationKey = coordinateKey .. ":" .. (entry.north and "north" or "west")
        local exactKey = orientationKey .. ":" .. entry.role
        if exactKeys[exactKey] then
            error("RailroaderRVTest: duplicate wall coordinate/orientation/role " .. exactKey)
        end
        if orientationKeys[orientationKey] then
            error("RailroaderRVTest: duplicate wall direction " .. orientationKey)
        end
        exactKeys[exactKey] = true
        orientationKeys[orientationKey] = true
        if not coordinateKeys[coordinateKey] then
            coordinateKeys[coordinateKey] = true
            uniqueCoordinates = uniqueCoordinates + 1
        end
        orientationByCoordinate[coordinateKey] = orientationByCoordinate[coordinateKey] or {}
        orientationByCoordinate[coordinateKey][entry.north and "north" or "west"] = true
        local expectedRole = entry.north and "wall-north" or "wall-west"
        local expectedSprite = entry.north and northWallSprite or westWallSprite
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = nwWallSprite
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = seWallSprite
            else
                error("RailroaderRVTest: corner wall is outside NW/SE")
            end
        end
        if entry.role ~= expectedRole or entry.sprite ~= expectedSprite then
            error("RailroaderRVTest: wall role does not match orientation at " .. coordinateKey)
        end
        if entry.north then northEdges = northEdges + 1 else westEdges = westEdges + 1 end
        if entry.corner then corners = corners + 1 end
    end
    for coordinateKey, orientations in pairs(orientationByCoordinate) do
        if orientations.north and orientations.west then
            error("RailroaderRVTest: wall ring cannot duplicate an orientation at " .. coordinateKey)
        end
    end
    if uniqueCoordinates ~= 92 or northEdges ~= 12 or westEdges ~= 80 or corners ~= 2 then
        error("RailroaderRVTest: wall contract must contain 92 coordinates/objects, north12/west80/corner2")
    end
    local function addWallAt(entry)
        local x, y = entry.x, entry.y
        local north, sprite, role = entry.north, entry.sprite, entry.role
        if entry.corner then
            local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(entry.z)
            if key == nwKey then
                sprite = nwWallSprite
            elseif key == seKey then
                sprite = seWallSprite
            else
                error("RailroaderRVTest: corner wall is outside NW/SE")
            end
        elseif north then
            sprite = northWallSprite
        else
            sprite = westWallSprite
        end
        local square = ServerWorld.getSquare(cell, x, y, bounds.z)
        if not square then
            error("RailroaderRVTest: wall square is not loaded")
        end
        createWall(cell, square, sprite, north, generation, role, {
            edgeKey = entry.edgeKey,
            axis = entry.axis or (north and "N" or "W"),
        }, tagContext)
    end
    for i = 1, #wallCoordinates do
        addWallAt(wallCoordinates[i])
    end

    setGenerationPhase(manifest, generation, "ROOF_FLOOR")
    -- The roof is ordinary flat floor on z+1, exactly over the 6x40 interior.
    -- Preflight proved the footprint is legal.  Missing upper-level squares
    -- are created through the official player-building path before addFloor.
    for x = bounds.roofMinX, bounds.roofMaxX do
        for y = bounds.roofMinY, bounds.roofMaxY do
            local square = ensureRoofSquare(cell, x, y, bounds.roofZ)
            createFloor(square, roofFloorSprite, generation, "roof-floor", tagContext)
        end
    end

    setGenerationPhase(manifest, generation, "STRUCTURE_RECALC")
    recalcAndCheckStructure(cell, bounds)

    setGenerationPhase(manifest, generation, "GENERATOR")
    local generatorPoint = ServerUtil.copyPoint(layout.generator, "layout.generator")
    local generatorSquare = ServerWorld.getSquare(cell, generatorPoint.x, generatorPoint.y, bounds.roofZ)
    if not generatorSquare then
        error("RailroaderRVTest: generator square is not loaded")
    end
    createGenerator(cell, generatorSquare, generatorSprite, generation, tagContext)

    setGenerationPhase(manifest, generation, "COUNTER_SINK")
    -- The sink is a normal native fixture.  Water connections create a
    -- separate hidden proxy above it; no visible collector is generated.
    local counterPoint = ServerUtil.copyPoint(layout.counter, "layout.counter")
    local sinkPoint = ServerUtil.copyPoint(layout.sink, "layout.sink")
    counterPoint.z, sinkPoint.z = bounds.z, bounds.z
    if sinkPoint.x == lightPoint.x and sinkPoint.y == lightPoint.y and sinkPoint.z == lightPoint.z then
        error("RailroaderRVTest: sink/light placement collides")
    end
    local counterSquare = ServerWorld.getSquare(cell, counterPoint.x, counterPoint.y, bounds.z)
    local sinkSquare = ServerWorld.getSquare(cell, sinkPoint.x, sinkPoint.y, bounds.z)
    if not counterSquare or not sinkSquare then
        error("RailroaderRVTest: counter or sink square is not loaded")
    end
    local counter = createFurniture(cell, counterSquare, counterSprite, generation,
        "counter", tagContext)
    if not ServerUtil.callSucceeded(counter, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: counter client transmission failed")
    end
    local sink = createFurniture(cell, sinkSquare, sinkSprite, generation, "sink",
        tagContext)
    -- The sink is already attached by createFurniture.  Publish its initial
    -- capability object before any later connection transaction can create a
    -- proxy or apply the native external-source bridge.
    if not ServerUtil.callSucceeded(sink, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: sink client transmission failed")
    end
    local sinkData = ServerWorld.objectModData(sink)
    if not sinkData then error("RailroaderRVTest: sink modData is unavailable") end
    sinkData.canBeWaterPiped = true
    if not ServerUtil.callSucceeded(sink, "transmitModData") then
        error("RailroaderRVTest: sink capability synchronisation failed")
    end

    local lightSquare = ServerWorld.getSquare(cell, lightPoint.x, lightPoint.y, lightPoint.z)
    if not lightSquare then
        error("RailroaderRVTest: light square is not loaded")
    end
    setGenerationPhase(manifest, generation, "LIGHT")
    -- The lamp is deliberately last: the structure, roof and generator are
    -- already attached, so the post-attach setActive/sync path has a valid
    -- square/object index and the failure rollback can remove all prior roles.
    createLight(cell, lightSquare, lightSprite, generation, tagContext)
end

local function markGenerationFailed(manifest, errorText)
    if not manifest then
        return true, nil
    end
    local empty = true
    for _ in pairs(manifest) do
        empty = false
        break
    end
    if empty then
        return true, nil
    end
    local ok, failure = pcall(function()
        manifest.phase = "FAILED"
        setManifestState(manifest, "FAILED", errorText)
    end)
    if ok then
        return true, nil
    end
    -- Keep a best-effort current-schema failure marker in memory/ModData.  No
    -- relocation transaction state is written; a process restart intentionally
    -- forgets all in-flight relocation state.
    local fallbackOk, fallbackFailure = pcall(function()
        manifest.phase = "FAILED"
        manifest.state = "FAILED"
        manifest.lastError = errorText
        manifest.updatedAt = math.floor(os.time())
    end)
    if fallbackOk then
        return false, safeErrorText(failure)
    end
    return false, safeErrorText(failure) .. " (fallback manifest update failed: "
        .. safeErrorText(fallbackFailure) .. ")"
end

local function finalizeGeneration(manifest, ok, resultOrError)
    local finalized, finalResult, finalReason = pcall(function()
        local finalizationFailure
        if not ok then
            local errorText = safeErrorText(resultOrError)
            local marked, markerFailure = markGenerationFailed(manifest, errorText)
            if not marked then
                finalizationFailure = markerFailure
            end
        end
        if not ok then
            local message = safeErrorText(resultOrError)
            if finalizationFailure then
                message = message .. " (manifest finalization failed: "
                    .. safeErrorText(finalizationFailure) .. ")"
            end
            if Boundary and type(Boundary.clearPlayer) == "function" then
                if ctx.pendingGeneration then ctx.pendingGeneration.boundaryCleared = true end
                pcall(Boundary.clearPlayer, ctx.transactionPlayer)
            end
            return false, message
        end
        return true, resultOrError
    end)
    -- This remains the single lock-release point for the synchronous build
    -- body.  An asynchronous final relocation keeps its own pending record.
    ctx.transactionBusy = false
    ctx.transactionPlayer = nil
    if not finalized then
        return false, safeErrorText(finalResult)
    end
    return finalResult, finalReason
end

-- Relocation state is process-local. The server keeps exact authoritative
-- coordinates and stable identities only while this process is alive; no
-- intermediate relocation record is read from or written to ModData.

ctx.setManifestState = setManifestState
ctx.manifestTable = manifestTable
ctx.setGenerationPhase = setGenerationPhase
ctx.clearGenerationArea = clearGenerationArea
ctx.buildGeneration = buildGeneration
ctx.markGenerationFailed = markGenerationFailed
ctx.finalizeGeneration = finalizeGeneration
ctx.safeErrorText = safeErrorText
end
