-- RV_BoundaryServer: player tracking and bounded proximity-queue work.
return function(ctx)
local Boundary = ctx.Boundary
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local identity = ctx.identity
local boundaryKey = ctx.boundaryKey
local transitionActive = ctx.transitionActive
local updatePlayer = ctx.updatePlayer
local playerPosition = ctx.playerPosition

local function collectionSnapshot(collection)
    local result = {}
    if collection == nil then return result end
    local sizeOk, size = call(collection, "size")
    size = sizeOk and integer(size) or nil
    if size ~= nil then
        for i = 0, size - 1 do
            local ok, object = call(collection, "get", i)
            if ok and object then result[#result + 1] = object end
        end
    elseif type(collection) == "table" then
        for _, object in pairs(collection) do
            if object then result[#result + 1] = object end
        end
    end
    return result
end

local function squareObjects(square)
    local result, seen = {}, {}
    local names = { "getObjects", "getSpecialObjects", "getWorldObjects",
        "getStaticMovingObjects", "getMovingObjects", "getDeadBodys" }
    for i = 1, #names do
        local ok, collection = call(square, names[i])
        if ok then
            for _, object in ipairs(collectionSnapshot(collection)) do
                if not seen[object] then
                    seen[object] = true
                    result[#result + 1] = object
                end
            end
        end
    end
    local floorOk, floor = call(square, "getFloor")
    if floorOk and floor and not seen[floor] then result[#result + 1] = floor end
    return result
end

local function onlinePlayersSnapshot()
    local result = {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        size = sizeOk and integer(size) or nil
        if size ~= nil then
            for i = 0, size - 1 do
                local playerOk, player = call(players, "get", i)
                if playerOk and player then result[#result + 1] = player end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do
                if player then result[#result + 1] = player end
            end
        end
    end
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if playerOk and player then result[1] = player end
    end
    return result
end

function Boundary.onTick()
    Boundary._tick = Boundary._tick + 1
    if type(Boundary.observeTemplateProtectionRepairTransitions) == "function" then
        local observeOk, observeResult = pcall(
            Boundary.observeTemplateProtectionRepairTransitions,
            Boundary._tick)
        if not observeOk or observeResult == false then
            print("[RailroaderRVTest] template-protection-repair transition observation skipped: "
                .. tostring(observeOk and "transition state unavailable" or observeResult))
        end
    end
    local players = onlinePlayersSnapshot()
    local activePlayers, activeBoundaries = {}, {}
    for i = 1, #players do
        local player = players[i]
        local position = playerPosition(player)
        if position then
            local id = identity(player)
            if id then
                local state = Boundary._states[id.key]
                if state then state.identity = id end
                -- Roof relocation owns the boundary lease while the player is
                -- temporarily outside the RV chunk. Normal position, queue,
                -- and guard work resumes only after transition completion.
                if not state or not transitionActive(state) then
                    local boundary = updatePlayer(player, position, id, true)
                    if boundary then
                        activePlayers[#activePlayers + 1] = {
                            boundary = boundary, player = player,
                        }
                        activeBoundaries[boundaryKey(boundary)] = {
                            boundary = boundary, player = player,
                        }
                    end
                end
            end
        end
    end

    if type(Boundary.shouldSampleTemplateProtectionRepair) == "function"
        and Boundary.shouldSampleTemplateProtectionRepair(Boundary._tick) then
        for i = 1, #activePlayers do
            local item = activePlayers[i]
            local callOk, sampled, reason = pcall(
                Boundary.sampleTemplateProtectionRepairPlayer,
                item.boundary, item.player)
            if not callOk or sampled ~= true then
                print("[RailroaderRVTest] template-protection-repair player sampling skipped: "
                    .. tostring(callOk and reason or sampled))
            end
        end
    end

    -- One queued XY tile is checked globally per server tick. Queue state is
    -- generation-scoped and processing pauses when no validated RV player is
    -- currently inside the owning 100x100 region.
    if type(Boundary.processTemplateProtectionRepairQueue) == "function" then
        local callOk, processed, reason = pcall(
            Boundary.processTemplateProtectionRepairQueue, activeBoundaries)
        if not callOk or processed ~= true and reason ~= nil then
            print("[RailroaderRVTest] template-protection-repair queue step skipped: "
                .. tostring(callOk and reason or processed))
        end
    end

    for key, builder in pairs(Boundary._builders) do
        if not builder or Boundary._tick > (builder.expires or 0) then
            Boundary._builders[key] = nil
        end
    end
end

end
