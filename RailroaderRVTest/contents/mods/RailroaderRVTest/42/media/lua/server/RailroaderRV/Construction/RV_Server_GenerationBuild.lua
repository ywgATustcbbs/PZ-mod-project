-- RV_Server: GenerationBuild responsibilities.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local ConstructionModule = require("RailroaderRV/Construction/RV_Construction")
local safeErrorText
local ensureRoofSquare = ctx.ensureRoofSquare
local createCapturedTemplateObject = ctx.createCapturedTemplateObject
local createGenerator = ctx.createGenerator
local ensureGeneratorForEntry = ctx.ensureGeneratorForEntry
local GenerationTransaction = ctx.GenerationTransaction

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

-- Generation has no durable mutation record.  Concurrency, phase and failure
-- state live in the process-local transaction (RV_Server_GenerationTransaction);
-- every geometric or schema fact is derived from the compiled template.
local function setGenerationPhase(generation, phase)
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
    for i = 1, #layout.templateObjects do
        local entry = layout.templateObjects[i]
        recalcAt(entry.x, entry.y, entry.z, true)
    end
    for i = 1, #bounds.wallCoordinates do
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

local function clearGenerationArea(cell, bounds, generation)
    setGenerationPhase(generation, "CLEARING")
    -- Scan the full managed bounds, including remnants from any failed earlier
    -- attempt. A new unmapped generation starts with this complete clear pass.
    ServerSchema.walkBounds(cell, bounds, function(square)
        ServerWorld.clearSquare(square, nil)
    end)
end

local function buildGeneration(player, layout, bounds, generation)
    local cell = ServerWorld.getCellForPlayer(player)
    local sprites = Constants.SPRITES
    local generatorSprite = sprites.generator.sprite

    -- Tags carry identity only; geometry is derived from the live square.
    local pending = GenerationTransaction.current()
    local tagContext = {
        rvId = pending and pending.rvId,
    }
    local templateObjects = layout.templateObjects
    local shellByTemplateIndex = {}
    for i = 1, #bounds.wallCoordinates do
        local edge = bounds.wallCoordinates[i]
        for partPosition = 1, #edge.templateIndices do
            local index = edge.templateIndices[partPosition]
            shellByTemplateIndex[index] = edge
        end
    end

    local generatorPoint = layout.generator

    setGenerationPhase(generation, "CAPTURED_TEMPLATE")
    for i = 1, #templateObjects do
        local entry = templateObjects[i]
        local square = ServerWorld.getSquare(cell, entry.x, entry.y, entry.z)
        if not square then
            square = ensureRoofSquare(cell, entry.x, entry.y, entry.z)
        end
        createCapturedTemplateObject(cell, square, entry, generation, tagContext,
            shellByTemplateIndex[i])
    end

    setGenerationPhase(generation, "STRUCTURE_RECALC")
    recalcAndCheckStructure(cell, bounds, layout)

    setGenerationPhase(generation, "GENERATOR")
    local generatorSquare = ServerWorld.getSquare(cell, generatorPoint.x,
        generatorPoint.y, generatorPoint.z)
    if not generatorSquare then
        error("RailroaderRVTest: generator square is not loaded")
    end
    createGenerator(cell, generatorSquare, generatorSprite, generation, tagContext)
end

local rawClearGenerationArea = clearGenerationArea
local rawBuildGeneration = buildGeneration
local construction = ConstructionModule.new(ctx, {
    clear = rawClearGenerationArea,
    build = rawBuildGeneration,
    setGenerationPhase = setGenerationPhase,
})
function construction.ensureGeneratorForEntry(player, record)
    if type(ensureGeneratorForEntry) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    return ensureGeneratorForEntry(player, record)
end
clearGenerationArea = construction.clearCurrentGeneration
buildGeneration = construction.buildCurrentGeneration

-- Relocation state is process-local. The server keeps exact authoritative
-- coordinates and stable identities only while this process is alive; no
-- intermediate relocation record is read from or written to ModData.

ctx.setGenerationPhase = setGenerationPhase
ctx.clearGenerationArea = clearGenerationArea
ctx.buildGeneration = buildGeneration
if type(ctx.RV) == "table" and type(ctx.RV.Server) == "table" then
    ctx.RV.Server.Construction = construction
end
ctx.safeErrorText = safeErrorText
end
