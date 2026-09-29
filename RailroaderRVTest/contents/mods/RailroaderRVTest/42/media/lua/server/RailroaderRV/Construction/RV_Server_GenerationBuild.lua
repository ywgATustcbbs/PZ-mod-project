-- RV_Server: GenerationBuild responsibilities.
return function(ctx)
local MANIFEST_KEY = ctx.MANIFEST_KEY
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local CapturedTemplate = require("RailroaderRV/RoomTemplate/RV_Template")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local capturedTemplateObjects = RoomTemplate.orderedObjects(Template)
local ConstructionModule = require("RailroaderRV/Construction/RV_Construction")
local ProtectionManifest = require("RailroaderRV/RoomTemplate/RV_ProtectionManifest")
local safeErrorText
local ensureRoofSquare = ctx.ensureRoofSquare
local createCapturedTemplateObject = ctx.createCapturedTemplateObject
local createGenerator = ctx.createGenerator

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
    end
    print("[RailroaderRVTest] generation=" .. tostring(generation)
        .. " phase=" .. tostring(phase))
end

local function recalcAndCheckStructure(cell, bounds, layout)
    local seen = {}
    local checked = 0
    local function recalcAt(x, y, z, required)
        local square = ServerWorld.getSquare(cell, x, y, z)
        if not square then
            if required then
                error("RailroaderRVTest: template structure square is not available")
            end
            return nil
        end
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if not seen[key] then
            seen[key] = true
            ServerWorld.recalcSquare(square)
            checked = checked + 1
        end
        return square
    end

    -- Rebuild room squares that exist, without materializing empty template
    -- cells. Every captured-object host is required because the build pass has
    -- just created or reused it.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            recalcAt(x, y, bounds.z, false)
        end
    end
    for i = 1, #(layout.templateObjects or {}) do
        local entry = layout.templateObjects[i]
        recalcAt(entry.x, entry.y, entry.z, true)
    end
    for i = 1, #(bounds.wallCoordinates or {}) do
        local entry = bounds.wallCoordinates[i]
        recalcAt(entry.x, entry.y, bounds.z, true)
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
    -- Scan the full managed bounds and clean only squares the cell currently
    -- has. Construction preflight rejects occupants that lack a complete undo
    -- path before this phase can mutate the world.
    ServerSchema.walkBounds(cell, bounds, function(square)
        ServerWorld.clearSquare(square, nil)
    end)
end

local function buildGeneration(player, layout, bounds, generation, manifest)
    local cell = ServerWorld.getCellForPlayer(player)
    local sprites = Constants.SPRITES
    local generatorSprite = sprites and sprites.generator and sprites.generator.sprite
    if not generatorSprite then
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
        anchorX = anchorX,
        anchorY = anchorY,
        anchorZ = anchorZ,
    }
    if tagContext.rvId == nil or tostring(tagContext.rvId) == ""
        or ServerUtil.toNumber(tagContext.bitmapVersion) == nil then
        error("RailroaderRVTest: generation boundary identity is incomplete")
    end
    local templateObjects = layout.templateObjects
    local protectionManifestValid, protectionManifestError =
        ProtectionManifest.validateTemplate(CapturedTemplate)
    local roomTemplateValid, roomTemplateError = RoomTemplate.validate(Template)
    if not roomTemplateValid or type(capturedTemplateObjects) ~= "table"
        or type(templateObjects) ~= "table"
        or #templateObjects ~= Template.metadata.objectCount
        or Template.metadata.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
        or Template.metadata.objectCount ~= 412 then
        error("RailroaderRVTest: current RoomTemplate object list is invalid: "
            .. tostring(roomTemplateError or "object count mismatch"))
    end
    if protectionManifestValid ~= true then
        error("RailroaderRVTest: captured protection ledger is invalid: "
            .. tostring(protectionManifestError))
    end
    local shellByTemplateIndex = {}
    for i = 1, #(bounds.wallCoordinates or {}) do
        local edge = bounds.wallCoordinates[i]
        if type(edge.templateIndices) ~= "table" or #edge.templateIndices < 1
            or edge.templateIndices[1] ~= edge.templateIndex then
            error("RailroaderRVTest: captured shell parts are incomplete")
        end
        for partPosition = 1, #edge.templateIndices do
            local index = ServerUtil.requiredInteger(edge.templateIndices[partPosition],
                "captured shell template part index")
            if shellByTemplateIndex[index] then
                error("RailroaderRVTest: duplicate captured shell template part index")
            end
            shellByTemplateIndex[index] = edge
        end
    end

    local function capturedObjectsAt(x, y, z)
        local result = {}
        for i = 1, #templateObjects do
            local entry = templateObjects[i]
            if entry.x == x and entry.y == y and entry.z == z then
                result[#result + 1] = entry
            end
        end
        return result
    end
    local function expectFloorOnly(point, role)
        local entries = capturedObjectsAt(point.x, point.y, point.z)
        if #entries ~= 1 or entries[1].class ~= "IsoObject" then
            error("RailroaderRVTest: " .. role
                .. " coordinate conflicts with a captured non-floor object")
        end
    end
    local function expectCapturedRoofObject(point, role)
        local entries = capturedObjectsAt(point.x, point.y, point.z)
        local entry = entries[1]
        local captured = entry and capturedTemplateObjects[entry.templateIndex]
        if #entries ~= 1 or type(entry) ~= "table"
            or entry.class ~= "IsoThumpable" or entry.z ~= bounds.roofZ
            or type(captured) ~= "table" or captured.class ~= entry.class
            or captured.sprite ~= entry.sprite then
            error("RailroaderRVTest: " .. role
                .. " coordinate is not a captured roof object square")
        end
    end
    local generatorPoint = ServerUtil.copyPoint(layout.generator, "layout.generator")
    if generatorPoint.z ~= bounds.roofZ then
        error("RailroaderRVTest: generator must remain on the captured roof level")
    end
    expectCapturedRoofObject(generatorPoint, "generator")
    local function sameCapturedState(actual, expected)
        if type(actual) ~= "table" or type(expected) ~= "table" then return false end
        for key, value in pairs(expected) do
            if actual[key] ~= value then return false end
        end
        for key in pairs(actual) do
            if expected[key] == nil then return false end
        end
        return true
    end

    setGenerationPhase(manifest, generation, "CAPTURED_TEMPLATE")
    for i = 1, #templateObjects do
        local entry = templateObjects[i]
        local captured = capturedTemplateObjects[i]
        if type(entry) ~= "table" or type(captured) ~= "table"
            or entry.templateIndex ~= i
            or entry.class ~= captured.class or entry.name ~= captured.name
            or entry.sprite ~= captured.sprite or entry.north ~= captured.north
            or entry.direction ~= captured.direction
            or not ProtectionManifest.matchesLayoutEntry(i, entry, anchor)
            or not sameCapturedState(entry.state, captured.state)
            or entry.x ~= anchorX + captured.x
            or entry.y ~= anchorY + captured.y
            or entry.z ~= anchorZ + captured.z then
            error("RailroaderRVTest: captured object differs from the current template at "
                .. tostring(i))
        end
        local square
        if entry.z == bounds.z or entry.z == bounds.roofZ then
            square = ServerWorld.getSquare(cell, entry.x, entry.y, entry.z)
            if not square then
                if type(ensureRoofSquare) ~= "function" then
                    error("RailroaderRVTest: template host square constructor is unavailable")
                end
                square = ensureRoofSquare(cell, entry.x, entry.y, entry.z)
            end
        else
            error("RailroaderRVTest: captured object host is outside base/roof z layers")
        end
        if not square then
            error("RailroaderRVTest: captured object host square could not be created")
        end
        createCapturedTemplateObject(cell, square, entry, generation, tagContext,
            shellByTemplateIndex[i])
    end

    setGenerationPhase(manifest, generation, "STRUCTURE_RECALC")
    recalcAndCheckStructure(cell, bounds, layout)

    setGenerationPhase(manifest, generation, "GENERATOR")
    local generatorSquare = ServerWorld.getSquare(cell, generatorPoint.x,
        generatorPoint.y, generatorPoint.z)
    if not generatorSquare then
        error("RailroaderRVTest: generator square is not loaded")
    end
    createGenerator(cell, generatorSquare, generatorSprite, generation, tagContext)
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

local function finalizeGeneration(manifest, ok, resultOrError,
    preserveManifestOnFailure)
    local finalized, finalResult, finalReason = pcall(function()
        local finalizationFailure
        if not ok and preserveManifestOnFailure ~= true then
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

local rawClearGenerationArea = clearGenerationArea
local rawBuildGeneration = buildGeneration
local construction = ConstructionModule.new(ctx, {
    clear = rawClearGenerationArea,
    build = rawBuildGeneration,
    setGenerationPhase = setGenerationPhase,
})
clearGenerationArea = construction.clearCurrentGeneration
buildGeneration = construction.buildCurrentGeneration

-- Relocation state is process-local. The server keeps exact authoritative
-- coordinates and stable identities only while this process is alive; no
-- intermediate relocation record is read from or written to ModData.

ctx.setManifestState = setManifestState
ctx.manifestTable = manifestTable
ctx.setGenerationPhase = setGenerationPhase
ctx.clearGenerationArea = clearGenerationArea
ctx.buildGeneration = buildGeneration
ctx.constructionService = construction
if type(ctx.RV) == "table" and type(ctx.RV.Server) == "table" then
    ctx.RV.Server.Construction = construction
end
ctx.markGenerationFailed = markGenerationFailed
ctx.finalizeGeneration = finalizeGeneration
ctx.safeErrorText = safeErrorText
end
