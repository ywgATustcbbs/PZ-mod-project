-- RV_RailroaderServer: the Enter/Exit command gate and the shared transaction
-- mutex read.
--
-- This module owns two things only: the online-player snapshot every adapter
-- path uses, and the one query that answers "may a seat/mapping/boundary change
-- happen right now".  A generation transaction and a wall reload operation both
-- mutate the same managed world scope, so the generic server tick reads the same
-- query through `serverTransactionMutexStatus`.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
local Adapter = ctx.Adapter
local C = ctx.C
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local playerId = ctx.playerId
local playerName = ctx.playerName
local sendResult = ctx.sendResult
local movePlayer = ctx.movePlayer
local enterPlayer = ctx.enterPlayer
local exitPlayer = ctx.exitPlayer

local function commandArgument(args, key)
    if args == nil then return nil end
    if type(args) == "table" then return args[key] end
    local ok, value = call(args, "get", key)
    return ok and value or nil
end

-- A wall reload operation owns the same scope as a generation, so Enter/Exit must
-- be refused for every player of the affected RV, not only its captured members.
local function wallReloadBusy(rvId)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.isWallReloadTransactionActive) ~= "function" then
        return true, "RV transaction gate is unavailable"
    end
    local callOk, active, reason = pcall(server.isWallReloadTransactionActive,
        rvId)
    if not callOk or type(active) ~= "boolean" then
        return true, "RV transaction gate is unavailable"
    end
    if active then
        return true, type(reason) == "string" and reason ~= "" and reason
            or "RV wall reload is in progress"
    end
    return false
end

function Adapter.OnClientCommand(module, command, player, args)
    if module ~= C.MOD_ID then return end
    if command ~= C.COMMAND_RV_ENTER and command ~= C.COMMAND_RV_EXIT then return end
    -- The transaction gate may reject before pcall is entered.  Treat that
    -- branch as an intentional handled result; otherwise the uninitialised `ok`
    -- below overwrites its real reason with `false`, which renders as the
    -- misleading "unknown reason" to the client.
    local ok, result, reason = true, nil, nil
    local busy, busyReason = wallReloadBusy(nil)
    if busy then
        result, reason = false, busyReason
    elseif command == C.COMMAND_RV_ENTER then
        local locoId = commandArgument(args, "locoId")
        if locoId == nil then
            result, reason = false, "locomotive id is missing"
        else
            ok, result, reason = pcall(enterPlayer, player, locoId)
        end
    else
        ok, result, reason = pcall(exitPlayer, player)
    end
    if not ok then result, reason = false, result end
    if result ~= true then
        print("[RailroaderRVTest] Railroader RV command rejected: "
            .. tostring(reason or "unknown reason"))
        sendResult(player, false, reason or "request rejected")
    end
end

local function onlinePlayersSnapshot()
    local result, seen = {}, {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        local count = integer(size)
        if sizeOk and count and count >= 0 then
            for index = 0, count - 1 do
                local playerOk, player = call(players, "get", index)
                if playerOk and player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do
                if player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        end
    end
    -- Single-player/co-op fallback when getOnlinePlayers is not exposed in the
    -- active Lua pass.  The server-side command path remains authoritative.
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if player then result[1] = player end
    end
    return result
end

-- Rebuild the client-side utility affordance after a reconnect from the
-- authoritative player identity and current persisted mapping.  This is only a
-- candidate hint: the utility command path calls resolveCurrentUtilityRV again,
-- so a stale client hint cannot grant access or select an RV.
function Adapter.onlinePlayersSnapshot()
    return onlinePlayersSnapshot()
end

function Adapter.syncUtilityMapping(player)
    local accepted, context = Adapter.resolveCurrentUtilityRV(player)
    if accepted ~= true or type(context) ~= "table"
        or type(context.identity) ~= "table"
        or type(context.record) ~= "table" then
        return false
    end
    local onlineId = playerId(player)
    local identity = context.identity
    local record = context.record
    if onlineId == nil or type(identity.rvId) ~= "string"
        or identity.rvId == "" or integer(identity.generation) == nil
        or record.locoId == nil then
        return false
    end
    local payload = {
        ok = true,
        onlineId = onlineId,
        rvId = tostring(identity.rvId),
        locoId = tostring(record.locoId),
        generation = integer(identity.generation),
    }
    local sentOk, sent = callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_UTILITY_MAPPING, payload)
    return sentOk and sent ~= false, identity
end

-- Read both halves of the service-wide transaction mutex before any adapter
-- path changes a seat, mapping, boundary lease or player position.  The wall
-- reload query deliberately receives no RV filter: one managed world scope
-- cannot safely run a second Enter/Exit or generation for another rvId.
Adapter.serverTransactionMutexStatus = function()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.isGenerationTransactionActive) ~= "function" then
        return nil, nil, "RV generation transaction state is unavailable"
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    if not generationCallOk or type(generationActive) ~= "boolean" then
        return nil, nil, C.INVALID_RV_DATA
    end
    local wallBusy, wallReason = wallReloadBusy(nil)
    return generationActive, wallBusy == true, wallReason
end

-- Enter/Exit must prove that the mapping record and the current persisted
-- manifest still describe one complete geometry before arming a boundary,
-- changing map.players/record.players, or sending a teleport.
Adapter.wallReloadTransactionBlocks = function(rvId)
    local generationBusy, wallBusy, mutexReason =
        Adapter.serverTransactionMutexStatus()
    if generationBusy == nil then
        return true, mutexReason
    end
    if generationBusy then
        return true, "RV generation transaction is in progress"
    end
    if wallBusy then
        return true, type(mutexReason) == "string" and mutexReason ~= ""
            and mutexReason or "RV wall reload is in progress"
    end
    return false
end

Adapter._ticks = Core.getTick()

-- The boundary validation module that Mapping assembles later reads the mutex
-- query through this shared context, and EntryExit asks the same context for the
-- generation/wall-reload blocking query, so both must resolve at call time.
ctx.onlinePlayersSnapshot = onlinePlayersSnapshot
ctx.serverTransactionMutexStatus = Adapter.serverTransactionMutexStatus
ctx.wallReloadTransactionBlocks = Adapter.wallReloadTransactionBlocks

-- PZ loads files in this directory alphabetically, so this adapter can be
-- evaluated before RV_Server.lua has created RailroaderRV.Server.  Register the
-- command handlers only once the public facade and its transaction queries
-- exist, and let RV_Server.lua call this installer again after it has built them.
function Adapter.installTransactionGate()
    if Adapter._gateInstalled then return true end
    local server = RailroaderRV and RailroaderRV.Server
    if type(server) ~= "table"
        or type(server.isGenerationTransactionActive) ~= "function"
        or type(server.isWallReloadTransactionActive) ~= "function" then
        return false
    end
    Adapter._gateInstalled = true
    Core.onCommand(C.COMMAND_RV_ENTER, Adapter.OnClientCommand)
    Core.onCommand(C.COMMAND_RV_EXIT, Adapter.OnClientCommand)
    return true
end

Adapter.installTransactionGate()
end
