-- Client intent/menu half of the Railroader RV adapter.
--
-- The client uses the clicked rr_loco only for the enter intent. Safehouse
-- claims carry no target hint; the server resolves the player's current RV.

require("RailroaderRV/Common/RV_Constants")
require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderContextMenu = RailroaderRV.RailroaderContextMenu or {}

local Menu = RailroaderRV.RailroaderContextMenu
local C = RailroaderRV.Constants

local ICON_ENTER_RV = "media/ui/RailroaderRV/enterrv.png"
local ICON_EXIT_RV = "media/ui/RailroaderRV/exitrv.png"
local ICON_UTILITY_DASHBOARD = "media/ui/RailroaderRV/managementpannel.png"

Menu._rvUtilityMapping = Menu._rvUtilityMapping or nil

local finiteNumber = C.finiteNumber
local finiteInteger = C.finiteInteger

local function text(key, fallback)
    local result = key
    pcall(function() result = getText(key) end)
    if not result or result == "" or result == key then return fallback end
    return result
end

local function localPlayer(playerNum)
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, player = pcall(getSpecificPlayer, playerNum)
    return ok and player or nil
end

local function localPlayerByOnlineId(onlineId)
    local count = 0
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok then count = finiteInteger(value) or 0 end
    end
    for playerNum = 0, count - 1 do
        local player = localPlayer(playerNum)
        if player then
            local ok, value = pcall(function() return player:getOnlineID() end)
            if ok and finiteInteger(value) == onlineId then return player end
        end
    end
    -- SP has no network slot and some B42 builds return nil/-1 from
    -- getOnlineID.  The server adapter's local fallback is slot 0, so resolve
    -- that one player without weakening MP online-id matching.
    if onlineId == 0 and count > 0 then return localPlayer(0) end
    return nil
end

local function playerPosition(player)
    if not player then return nil end
    local okX, x = pcall(function() return player:getX() end)
    local okY, y = pcall(function() return player:getY() end)
    local okZ, z = pcall(function() return player:getZ() end)
    x, y, z = finiteNumber(x), finiteNumber(y), finiteNumber(z)
    if not okX or not okY or not okZ or not x or not y or not z then return nil end
    return { x = x, y = y, z = z }
end

local function targetRegion()
    local firstSlot = RegionSlots.indexToRegion(1)
    local lastSlot = RegionSlots.indexToRegion(RegionSlots.COUNT)
    local anchor = RegionSlots.indexToAnchor(1)
    return { minX = firstSlot.minX, minY = firstSlot.minY,
        maxX = lastSlot.maxX, maxY = lastSlot.maxY,
        minZ = anchor.z + C.RV_MANAGED_MIN_Z_OFFSET,
        maxZ = anchor.z + C.RV_MANAGED_MAX_Z_OFFSET }
end

local function inRegion(position, region)
    if not position or not region then return false end
    local minZ = finiteNumber(region.minZ)
    local maxZ = finiteNumber(region.maxZ)
    return position.x >= region.minX and position.x < region.maxX
        and position.y >= region.minY and position.y < region.maxY
        and minZ ~= nil and maxZ ~= nil
        and math.floor(position.z) >= math.floor(minZ)
        and math.floor(position.z) < math.floor(maxZ)
end

local function mapContainsPlayer(player)
    local position = playerPosition(player)
    if not position then return false end
    local target = targetRegion()
    if not inRegion(position, target) then return false end
    -- The server mapping gate is authoritative.  The client only decides
    -- whether to show the local affordance from its fixed coordinate scope.
    return true
end

local function validUtilityMapping(value)
    return type(value) == "table"
        and type(value.rvId) == "string" and value.rvId ~= ""
        and type(value.locoId) == "string" and value.locoId ~= ""
        and finiteInteger(value.generation) ~= nil
        and finiteInteger(value.generation) >= 1
end

local function rememberUtilityMapping(args)
    if type(args) ~= "table" then return end
    local action = tostring(args.action or "")
    if action ~= "enter" and action ~= "exit" then return end
    local mapping = {
        rvId = tostring(args.rvId or ""),
        locoId = tostring(args.locoId or ""),
        generation = finiteInteger(args.generation),
    }
    if validUtilityMapping(mapping) then
        Menu._rvUtilityMapping = mapping
    end
end

local function isIsoAnimal(animal)
    if not animal or type(instanceof) ~= "function" then return false end
    local ok, result = pcall(instanceof, animal, "IsoAnimal")
    return ok and result == true
end

local function locomotiveType(animal)
    if not isIsoAnimal(animal) then return nil end
    local ok, value = pcall(function() return animal:getAnimalType() end)
    return ok and tostring(value) or nil
end

local function isLocomotive(animal)
    return locomotiveType(animal) == "rr_loco"
end

local function locomotiveId(animal)
    if not animal then return nil end
    local ok, value = pcall(function() return animal:getAnimalID() end)
    return ok and value or nil
end

local function optionAlreadyExists(context, label)
    local options = context and context.options
    if type(options) ~= "table" then return false end
    local count = finiteInteger(context.numOptions) or #options
    for index = 1, count do
        local option = options[index]
        if type(option) == "table" then
            local name = option.name or option.label
            if name == label then return true end
        end
    end
    return false
end

local function markTest()
    if ISWorldObjectContextMenu and type(ISWorldObjectContextMenu.setTest) == "function" then
        pcall(ISWorldObjectContextMenu.setTest)
    end
    return true
end

local function requestEnter(player, locoId)
    if not player or locoId == nil then return end
    print("[RailroaderRV] sending EnterRV loco=" .. tostring(locoId))
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_ENTER, {
        locoId = locoId,
    })
end

local function requestExit(player)
    if not player then
        return
    end
    print("[RailroaderRV] sending ExitRV")
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_EXIT, {})
end

local function requestSafehouseClaim(player)
    if not player then return end
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_CLAIM, {})
end

local function addExit(playerNum, context, test)
    local label = text("ContextMenu_RailroaderRV_Exit", "Exit RV")
    if optionAlreadyExists(context, label) then
        return true
    end
    local optionPlayer = localPlayer(playerNum)
    if test then
        context:addOption(label, optionPlayer, requestExit)
        return markTest()
    end
    local option = context:addOption(label, optionPlayer, requestExit)
    option.iconTexture = getTexture(ICON_EXIT_RV)
    return true
end

local function addSafehouseClaim(playerNum, context, test)
    local player = localPlayer(playerNum)
    if not player or not Menu.getUtilityMapping()
        or not mapContainsPlayer(player) then return false end
    local claimLabel = text("ContextMenu_RailroaderRV_ClaimSafehouse",
        "Claim RV Safehouse")
    if optionAlreadyExists(context, claimLabel) then return true end
    context:addOption(claimLabel, player, requestSafehouseClaim)
    if test then return markTest() end
    return true
end

local function nearestLocomotive()
    local rr = rawget(_G, "RR")
    local ride = rr and rr.Ride
    if not ride or type(ride.nearestBoardable) ~= "function" then return nil end
    -- Railroader 2.1 publishes the same hull-distance reach used by E.
    -- Do not replace it with a centre-radius approximation.
    local reach = finiteNumber(ride.MOUNT_REACH)
        or finiteNumber(C.RV_MOUNT_REACH)
        or 2.0
    local record
    local ok = pcall(function()
        record = ride.nearestBoardable(reach)
    end)
    if ok and type(record) == "table" and isLocomotive(record.animal) then
        return record.animal
    end
    return nil
end

function Menu.getUtilityMapping()
    local mapping = Menu._rvUtilityMapping
    if not validUtilityMapping(mapping) then return nil end
    return {
        rvId = mapping.rvId, locoId = mapping.locoId,
        generation = mapping.generation,
    }
end

-- Reconnect recovery is a server-created candidate only. The payload does
-- not grant permission or carry coordinates. Every utility command still
-- performs the complete server-side mapping/range gate.
function Menu.acceptUtilityMapping(args)
    if type(args) ~= "table" or args.ok ~= true then return false end
    local onlineId = finiteInteger(args.onlineId)
    if onlineId == nil or not localPlayerByOnlineId(onlineId) then return false end
    local mapping = {
        rvId = tostring(args.rvId or ""),
        locoId = tostring(args.locoId or ""),
        generation = finiteInteger(args.generation),
    }
    if not validUtilityMapping(mapping) then return false end
    Menu._rvUtilityMapping = mapping
    return true
end

function Menu.clearUtilityMapping()
    Menu._rvUtilityMapping = nil
end

function Menu.hasUtilityDashboardCandidate(player, insideOnly, locomotiveIdHint)
    local mapping = Menu.getUtilityMapping()
    if not mapping or not player then return false end
    if mapContainsPlayer(player) then return true end
    if insideOnly then return false end
    local id = locomotiveIdHint
    if id == nil then
        local locomotive = nearestLocomotive()
        if not locomotive then return false end
        id = locomotiveId(locomotive)
    end
    return id ~= nil and tostring(id) == mapping.locoId
end

local function addLocomotiveOptions(playerNum, context, animal, test)
    if not context or not isLocomotive(animal) then return false end
    local player = localPlayer(playerNum)
    local locoId = locomotiveId(animal)
    if not player or locoId == nil then return false end

    local enterLabel = text("ContextMenu_RailroaderRV_Enter", "Enter RV")
    local dashboardLabel = text("ContextMenu_RailroaderRV_UtilityDashboard",
        "RV utility panel")
    local hasEnter = optionAlreadyExists(context, enterLabel)
    local hasDashboard = optionAlreadyExists(context, dashboardLabel)
    local showDashboard = Menu.hasUtilityDashboardCandidate(player, false, locoId)

    if test then
        if not hasEnter or (showDashboard and not hasDashboard) then
            return markTest()
        end
        return false
    end

    if not hasEnter then
        local option = context:addOption(enterLabel, player, requestEnter, locoId)
        option.iconTexture = getTexture(ICON_ENTER_RV)
    end
    if showDashboard and not hasDashboard then
        local option = context:addOption(dashboardLabel, player,
            RailroaderRV.UtilityContextMenu.openDashboard)
        option.iconTexture = getTexture(ICON_UTILITY_DASHBOARD)
    end
    return true
end

local function addNearbyLocomotiveOptions(playerNum, context, test, clickedAnimal)
    local animal = nearestLocomotive()
    if not animal then return false end
    if clickedAnimal
        and locomotiveId(clickedAnimal) ~= locomotiveId(animal) then
        return false
    end
    return addLocomotiveOptions(playerNum, context, animal, test)
end

local function patchRailroaderAnimalMenu()
    local boardMenu = RR.BoardMenu
    if boardMenu.rrRVRailroaderAnimalMenuWrapped then return end
    local originalAddForAnimal = boardMenu.addForAnimal
    boardMenu.addForAnimal = function(playerNum, context, animal, test, ...)
        local result = originalAddForAnimal(playerNum, context, animal, test, ...)
        addNearbyLocomotiveOptions(playerNum, context, test, animal)
        return result
    end
    boardMenu.rrRVRailroaderAnimalMenuWrapped = true
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        value = finiteNumber(value)
        if ok and value then return value end
    end
    return os.time() * 1000
end

-- The generation transaction can spend longer than Ride's two-second stale
-- snapshot grace waiting for the remote footprint.  Keep a token-scoped
-- marker so a repeated FinalRelocate callback does not call dismount a second
-- time (dismount(true) may place the player beside the locomotive).  A new
-- generation gets a new server token, so it can still start a fresh cleanup
-- even when the same locomotive is used again.
local GENERATION_TRANSITION_TTL_MS = 300000
local CURRENT_SQUARE_REFRESH_TICKS = 120

local function generationTransitionMatches(pending, args)
    if type(pending) ~= "table" or type(args) ~= "table" then return false end
    local generation = finiteInteger(args.generation)
    if pending.rvId == nil or args.rvId == nil
        or tostring(pending.rvId) ~= tostring(args.rvId)
        or pending.generation == nil or generation ~= pending.generation then
        return false
    end
    if pending.token ~= nil and args.token ~= nil then
        return tostring(pending.token) == tostring(args.token)
    end
    return pending.locoId ~= nil and args.locoId ~= nil
        and tostring(pending.locoId) == tostring(args.locoId)
end

local function activeGenerationTransition()
    local pending = Menu._rvGenerationTransition
    if type(pending) == "table" and pending.expiresAt ~= nil
        and nowMs() > pending.expiresAt then
        Menu._rvGenerationTransition = nil
        return nil
    end
    return pending
end

local function localTrainRecord(locoId)
    local rr = rawget(_G, "RR")
    local active = rr and rr.TrainEntity and rr.TrainEntity.active
    if type(active) ~= "table" or locoId == nil then return nil end
    local wanted = tostring(locoId)
    for _, record in pairs(active) do
        if type(record) == "table" then
            local id = record.id
            if id == nil and record.animal then
                pcall(function() id = record.animal:getAnimalID() end)
            end
            if id ~= nil and tostring(id) == wanted then return record end
        end
    end
    return nil
end

-- RVTeleport is delivered around the same time as Railroader's seat snapshot.
-- Let the official Ride API clear a local seat before the RV coordinate write;
-- Ride.dismount(true) also arms Railroader's documented stale-snapshot grace,
-- preventing RR_MPClient from calling placePlayerBeside after this teleport.
local function prepareRideTransition(args)
    local action = tostring(args.action or "")
    local rr = rawget(_G, "RR")
    local ride = rr and rr.Ride
    local record = localTrainRecord(args.locoId)
    if action == "generation-failed" then
        -- A failed generation ends the one-shot staging transition.  The
        -- server snapshot that follows is then allowed to restore the seat.
        Menu._rvGenerationTransition = nil
    end
    if not ride then return record end
    if action == "enter" or action == "generation-failed" then
        if ride.current and type(ride.dismount) == "function" then
            pcall(ride.dismount, true)
        end
        -- A failed generation restores the old official seat on the server.
        -- `_boardPending` is only the local RR_MPClient stale-packet gate; the
        -- subsequent official snapshot still decides whether mountRecord runs.
        if action == "generation-failed" and record
            and (args.role == "driver" or args.role == "passenger") then
            record._boardPending = true
        end
    elseif action == "exit" then
        -- Set the target record's official stale-snapshot gate even when the
        -- local Ride state was already cleared.  This closes the quick-exit
        -- race during the enter dismount grace.  Beside exits intentionally
        -- do not set _boardPending and never fabricate a seat.
        local wantsSeat = args.role == "driver" or args.role == "passenger"
        if wantsSeat and record then
            record._boardPending = true
        end
        if ride.current then
            -- A partial/stale snapshot may still have the old local seat.
            -- Clear it through Ride, then allow the server's new snapshot to
            -- mount officially.
            local old = ride.current
            if type(ride.dismount) == "function" then
                pcall(ride.dismount, true)
            end
            if wantsSeat and old then old._boardPending = true end
        end
    end
    return record
end

-- IsoGameCharacter:teleportTo writes the coordinates but deliberately leaves
-- IsoMovingObject.current untouched until a normal movement/collision update.
-- Refresh that client cache only after the server-selected teleport.  The
-- official three-argument overload performs a read-only grid lookup and then
-- assigns current; it does not replace the server-authoritative roof refresh
-- (the server's temporary west-neighbour floor transaction does that).
-- Never assign Java IsoPlayer fields from Lua here: Kahlua userdata is not a
-- table, so a field write raises "attempted index of non-table" every tick.
local function refreshCurrentSquare(player, x, y, z)
    if not player or type(player.setCurrentSquareFromPosition) ~= "function" then
        return false
    end
    local ok = pcall(function()
        player:setCurrentSquareFromPosition(x, y, z)
    end)
    return ok
end

local function currentSquareMatches(player, x, y, z)
    if not player or type(player.getCurrentSquare) ~= "function" then
        return false
    end
    local ok, square = pcall(function() return player:getCurrentSquare() end)
    if not ok or not square then return false end
    local okX, squareX = pcall(function() return square:getX() end)
    local okY, squareY = pcall(function() return square:getY() end)
    local okZ, squareZ = pcall(function() return square:getZ() end)
    return okX and okY and okZ
        and finiteInteger(squareX) == math.floor(x)
        and finiteInteger(squareY) == math.floor(y)
        and finiteInteger(squareZ) == math.floor(z)
end

local function playerStillAtTargetSquare(player, x, y, z)
    if not player then return nil end
    local okX, currentX = pcall(function() return player:getX() end)
    local okY, currentY = pcall(function() return player:getY() end)
    local okZ, currentZ = pcall(function() return player:getZ() end)
    currentX, currentY, currentZ = finiteNumber(currentX),
        finiteNumber(currentY), finiteNumber(currentZ)
    if not okX or not okY or not okZ
        or currentX == nil or currentY == nil or currentZ == nil then
        return nil
    end
    return math.floor(currentX) == math.floor(x)
        and math.floor(currentY) == math.floor(y)
        and math.floor(currentZ) == math.floor(z)
end

local function scheduleCurrentSquareRefresh(player, x, y, z, relation)
    if not player then return end
    Menu._rvCurrentSquareRefresh = {
        player = player,
        x = x,
        y = y,
        z = z,
        ticks = 0,
        rvId = type(relation) == "table" and relation.rvId or nil,
        generation = type(relation) == "table"
            and finiteInteger(relation.generation) or nil,
    }
    refreshCurrentSquare(player, x, y, z)
    if currentSquareMatches(player, x, y, z) then
        Menu._rvCurrentSquareRefresh = nil
    end
end

function Menu.onTick()
    local pending = Menu._rvCurrentSquareRefresh
    if type(pending) ~= "table" then return end
    pending.ticks = pending.ticks + 1
    local player = pending.player
    if not player or pending.ticks > CURRENT_SQUARE_REFRESH_TICKS then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    -- This bounded refresh belongs only to its server-selected RV teleport.
    -- If another system has since moved the player, leave that system's
    -- current-square state alone instead of restoring this stale target.
    if playerStillAtTargetSquare(player, pending.x, pending.y, pending.z) == false then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    if currentSquareMatches(player, pending.x, pending.y, pending.z) then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    refreshCurrentSquare(player, pending.x, pending.y, pending.z)
    if currentSquareMatches(player, pending.x, pending.y, pending.z) then
        Menu._rvCurrentSquareRefresh = nil
    end
end

local function finishRideTransition(args, record, player)
    local rr = rawget(_G, "RR")
    local ride = rr and rr.Ride
    if not ride or (args.action ~= "exit" and args.action ~= "generation-failed")
        or rr.MPClient then return end
    -- In SP there is no RR_MPClient snapshot.  Use the official Ride API after
    -- the authoritative teleport, never by fabricating rider/seat fields.
    if record and (args.role == "driver" or args.role == "passenger")
        and type(ride.mountRecord) == "function" then
        pcall(ride.mountRecord, record, true, finiteInteger(args.seat) or 0)
    end
end

local function validGenerationFinalHint(args)
    local generation = type(args) == "table" and finiteInteger(args.generation)
    return type(args) == "table" and args.railroaderTransition == true
        and type(args.token) == "string" and args.token ~= ""
        and args.locoId ~= nil and tostring(args.locoId) ~= ""
        and args.rvId ~= nil and tostring(args.rvId) ~= ""
        and generation ~= nil and generation >= 1
end

-- Called by RV_ContextMenu's generic FinalRelocate bridge.  It shares the
-- exact enter ordering with RVTeleport, including Railroader's stale-snapshot
-- dismount grace, while leaving final coordinates under the server command.
function Menu.prepareGenerationRelocation(args)
    if type(args) ~= "table" then return false end
    local pending = activeGenerationTransition()
    if pending and generationTransitionMatches(pending, args) then
        -- The staging handler already performed the only Ride dismount for
        -- this token.  Keep the marker through duplicate command callbacks;
        -- the final coordinates are still applied by RV_ContextMenu from the
        -- server payload immediately below this hook.
        pending.finalSeen = true
        pending.expiresAt = nowMs() + GENERATION_TRANSITION_TTL_MS
        rememberUtilityMapping(args)
        return true
    end
    -- Never infer Railroader state from the generic technical FinalRelocate.
    -- A marker must be server-created and carry the same token/loco identity
    -- used by the staging transition.
    if not validGenerationFinalHint(args) then return false end
    args.action = args.action or "enter"
    rememberUtilityMapping(args)
    prepareRideTransition(args)
    Menu._rvGenerationTransition = {
        token = args.token,
        locoId = args.locoId,
        rvId = tostring(args.rvId),
        generation = finiteInteger(args.generation),
        finalSeen = true,
        expiresAt = nowMs() + GENERATION_TRANSITION_TTL_MS,
    }
    return true
end

-- Called only for the server-created Relocate marker.  This is intentionally
-- separate from generic Generate so a technical generation can never touch a
-- local Railroader Ride state by accident.
function Menu.prepareGenerationStaging(args)
    if not validGenerationFinalHint(args) then
        return false
    end
    local pending = activeGenerationTransition()
    if pending and generationTransitionMatches(pending, args) then
        return true
    end
    args.action = "enter"
    prepareRideTransition(args)
    Menu._rvGenerationTransition = {
        token = args.token,
        locoId = args.locoId,
        rvId = tostring(args.rvId),
        generation = finiteInteger(args.generation),
        expiresAt = nowMs() + GENERATION_TRANSITION_TTL_MS,
    }
    return true
end

function Menu.OnFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context then return end
    local player = localPlayer(playerNum)
    if not player then
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        return
    end
    if not mapContainsPlayer(player) then
        addNearbyLocomotiveOptions(playerNum, context, test)
        return
    end
    addExit(playerNum, context, test)
    addSafehouseClaim(playerNum, context, test)
end

-- The vanilla world-menu pipeline fires OnPreFillWorldObjectContextMenu before
-- it decides whether the clicked square has a fetchable world object.  Inside
-- a generated RV the player will often right-click an ordinary floor square,
-- so the later OnFillWorldObjectContextMenu event is skipped when fetch.c == 0.
-- Exit is a player-state action and must remain available on those empty
-- squares, including after reconnect when the live locomotive may be absent.
function Menu.OnPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context then return end
    local player = localPlayer(playerNum)
    if not player then
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        return
    end
    local inside = mapContainsPlayer(player)
    if not inside then
        addNearbyLocomotiveOptions(playerNum, context, test)
        return
    end
    addExit(playerNum, context, test)
    addSafehouseClaim(playerNum, context, test)
end

function Menu.OnServerCommand(module, command, args)
    if module ~= C.MOD_ID or type(args) ~= "table" then return end
    if command == C.COMMAND_RV_SAFEHOUSE_SYNC then
        SafeHouse.addSafeHouse(args.x, args.y, args.w, args.h, args.owner)
        local player = localPlayerByOnlineId(finiteInteger(args.onlineId))
        if player then
            local message = text("UI_RailroaderRV_Safehouse_Claimed",
                "The RV driver's cab is now your safehouse.")
            player:setHaloNote(message, 100, 255, 100, 5000)
        end
        return
    elseif command == C.COMMAND_RV_SAFEHOUSE_RESULT then
        local reasonKeys = {
            ["invalid-request"] = "UI_RailroaderRV_Safehouse_Reject_InvalidRequest",
            ["player-unavailable"] = "UI_RailroaderRV_Safehouse_Reject_PlayerUnavailable",
            ["rv-not-found"] = "UI_RailroaderRV_Safehouse_Reject_NotGenerated",
            ["rv-not-active"] = "UI_RailroaderRV_Safehouse_Reject_NotActive",
            ["busy"] = "UI_RailroaderRV_Safehouse_Reject_Busy",
            ["outside-rv"] = "UI_RailroaderRV_Safehouse_Reject_Inside",
            ["permission-denied"] = "UI_RailroaderRV_Safehouse_Reject_Permission",
            ["water-tanks-missing"] = "UI_RailroaderRV_Safehouse_Reject_Tanks",
            ["water-pump-missing"] = "UI_RailroaderRV_Safehouse_Reject_Pump",
            ["water-filter-missing"] = "UI_RailroaderRV_Safehouse_Reject_Filter",
            ["water-unpowered"] = "UI_RailroaderRV_Safehouse_Reject_Power",
            ["water-filter-exhausted"] = "UI_RailroaderRV_Safehouse_Reject_FilterExhausted",
            ["safehouse-overlap"] = "UI_RailroaderRV_Safehouse_Reject_Overlap",
        }
        local player = localPlayerByOnlineId(finiteInteger(args.onlineId))
        if player then
            local key = assert(reasonKeys[args.reason],
                "RailroaderRV: unknown safehouse claim result")
            local message = text(key, "The RV safehouse claim was rejected.")
            player:setHaloNote(message, 255, 80, 80, 5000)
        end
        return
    end
    if command ~= C.COMMAND_RV_TELEPORT then return end
    local onlineId = finiteInteger(args.onlineId)
    if args.ok == false then
        if args.reason == C.INVALID_RV_DATA then
            local player = onlineId and localPlayerByOnlineId(onlineId) or nil
            if player and type(player.setHaloNote) == "function" then
                local message = text("UI_RailroaderRV_InvalidRVData",
                    "RV data is invalid. Delete this save and recreate it.")
                pcall(function()
                    player:setHaloNote(message, 255, 255, 255, 5000)
                end)
            end
        end
        if args.reason then print("[RailroaderRV] " .. tostring(args.reason)) end
        return
    end
    rememberUtilityMapping(args)
    local x, y, z = finiteNumber(args.x), finiteNumber(args.y), finiteNumber(args.z)
    if onlineId == nil or x == nil or y == nil or z == nil
        or z < -32 or z > 31 then return end
    local player = localPlayerByOnlineId(onlineId)
    if not player then return end
    local record = prepareRideTransition(args)
    local teleported = pcall(function() player:teleportTo(x, y, z) end)
    if teleported then
        scheduleCurrentSquareRefresh(player, x, y, z, args)
    end
    finishRideTransition(args, record, player)
end

if Events and Events.OnGameStart and type(Events.OnGameStart.Add) == "function" then
    Events.OnGameStart.Add(patchRailroaderAnimalMenu)
end
if Events and Events.OnFillWorldObjectContextMenu
    and type(Events.OnFillWorldObjectContextMenu.Add) == "function" then
    Events.OnFillWorldObjectContextMenu.Add(Menu.OnFillWorldObjectContextMenu)
end
if Events and Events.OnPreFillWorldObjectContextMenu
    and type(Events.OnPreFillWorldObjectContextMenu.Add) == "function" then
    Events.OnPreFillWorldObjectContextMenu.Add(Menu.OnPreFillWorldObjectContextMenu)
end
if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Menu.OnServerCommand)
end
if Events and Events.OnConnected and type(Events.OnConnected.Add) == "function" then
    Events.OnConnected.Add(Menu.clearUtilityMapping)
end
if Events and Events.OnDisconnect and type(Events.OnDisconnect.Add) == "function" then
    Events.OnDisconnect.Add(Menu.clearUtilityMapping)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function"
    and not Menu._rvCurrentSquareRefreshHook then
    Events.OnTick.Add(Menu.onTick)
    Menu._rvCurrentSquareRefreshHook = true
end

return Menu
