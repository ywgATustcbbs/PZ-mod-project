-- Server authority for flatcar binding and real vehicle load/unload.
return function(ctx)
    local C = ctx.C
    local ClientDispatch = ctx.ClientDispatch
    local ServerWorld = ctx.ServerWorld
    local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
    local Units = require("RailroaderRV/RVMapping/RV_RailroaderUnits")
    local CargoCatalog = require("RailroaderRV/Cargo/RV_FlatcarCargoCatalog")
    local State = require("RailroaderRV/VehicleTransport/RV_VehicleTransportState")
    local Placement = require("RailroaderRV/VehicleTransport/RV_VehicleTransportPlacement")

    local function mapData()
        return ModData.get(C.RV_MAP_KEY)
    end

    local function manifest(cars)
        local result = {}
        for index, car in ipairs(cars) do
            result[index] = {
                cargoId = car.cargoId,
                vehicleScript = car.vehicleScript,
                center = car.center,
                visual = car.visual,
            }
        end
        return result
    end

    local function logResolvedTarget(operation, target)
        local geometry = target.geometry
        CargoCatalog.debug(
            "server %s target unitId=%s owner=%s kind=%s pose=(%.3f,%.3f,%.3f) hullDistance=%.3f",
            operation, target.key,
            tostring(target.unit.locomotiveId or "cut"),
            target.unit.kind, geometry.x, geometry.y, geometry.z,
            geometry.hullDistanceTiles)
    end

    local function snapshot(player)
        local playerOk, reason = validateAuthoritativePlayer(player)
        if not playerOk then return false, reason end
        local units = {}
        for unitId, state in pairs(mapData().flatcars) do
            units[#units + 1] = { unitId = unitId, cars = manifest(state.cars) }
        end
        table.sort(units, function(first, second)
            return first.unitId < second.unitId
        end)
        ClientDispatch.sendToPlayer(player, C.MOD_ID,
            C.COMMAND_RV_FLATCAR_SYNC, { units = units })
        return true
    end

    local function resolveConversionTarget(player, args)
        local playerOk, positionOrReason = validateAuthoritativePlayer(player)
        if not playerOk then return nil, positionOrReason end
        local unitId = C.finiteInteger(args.unitId)
        if unitId == nil then return nil, "invalid-unit" end
        local unit = Units.find(unitId)
        if not unit or unit.kind ~= "car_bx40" then
            return nil, "not-bx40"
        end
        local position = positionOrReason
        local geometry = Units.geometry(unit, position.x, position.y)
        if not geometry or geometry.hullDistanceTiles == nil
                or geometry.hullDistanceTiles > C.RV_MOUNT_REACH then
            return nil, "outside-reach"
        end
        if geometry.z == nil or math.floor(geometry.z) ~= position.z then
            return nil, "different-level"
        end

        local key = tostring(unit.id)
        local cell = ServerWorld.getCellForPlayer(player)
        local targetSquare = ServerWorld.getSquare(cell,
            math.floor(geometry.x), math.floor(geometry.y),
            math.floor(geometry.z))
        if targetSquare == nil then return nil, "target-not-loaded" end
        return { unit = unit, geometry = geometry, key = key }
    end

    local function resolveCargoTarget(player, args)
        local playerOk, positionOrReason = validateAuthoritativePlayer(player)
        if not playerOk then return nil, positionOrReason end

        local unitId = C.finiteInteger(args.unitId)
        if unitId == nil then return nil, "invalid-unit" end
        local unit = Units.find(unitId)
        if not unit or unit.kind ~= "car_bx40" then
            return nil, "not-bx40"
        end
        local position = positionOrReason
        -- Reach needs the player's world point, not the validator's floored square.
        local geometry = Units.geometry(unit, player:getX(), player:getY())
        if not geometry or geometry.hullDistanceTiles == nil
                or geometry.hullDistanceTiles > C.RV_MOUNT_REACH then
            return nil, "outside-reach"
        end
        if geometry.z == nil or math.floor(geometry.z) ~= position.z then
            return nil, "different-level"
        end

        local cell = ServerWorld.getCellForPlayer(player)
        local targetSquare = ServerWorld.getSquare(cell,
            math.floor(geometry.x), math.floor(geometry.y),
            math.floor(geometry.z))
        if targetSquare == nil then return nil, "target-not-loaded" end

        local key = tostring(unit.id)
        local flatcar = mapData().flatcars[key]
        if not flatcar then return nil, "not-flatcar" end
        return {
            unit = unit,
            geometry = geometry,
            position = position,
            key = key,
            flatcar = flatcar,
            cell = cell,
        }
    end

    local function broadcastFlatcar(unitId, flatcar)
        ClientDispatch.broadcast(C.MOD_ID, C.COMMAND_RV_FLATCAR_SYNC, {
            unitId = unitId,
            cars = manifest(flatcar.cars),
        })
    end

    local function commitUnboundConversion(target)
        local map = mapData()
        local flatcar = { cars = {} }
        map.flatcars[target.key] = flatcar
        broadcastFlatcar(target.key, flatcar)
        return true
    end

    local function convert(player, args)
        local target, reason = resolveConversionTarget(player, args)
        if not target then return false, reason end
        local map = mapData()
        if map.flatcars[target.key] then return false, "already-flatcar" end
        if map.locomotives[target.key] then
            return false, "bound-rv-cannot-convert"
        end
        return commitUnboundConversion(target)
    end

    local function collectContainerItems(vehicle)
        local entries, seenContainers = {}, {}
        local function appendContainer(container)
            if container ~= nil and not seenContainers[container] then
                seenContainers[container] = true
                local items = container:getItems()
                for itemIndex = 0, items:size() - 1 do
                    entries[#entries + 1] = {
                        container = container,
                        item = items:get(itemIndex),
                    }
                end
            end
        end

        for partIndex = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(partIndex)
            appendContainer(part:getItemContainer())
        end

        local key = vehicle:getCurrentKey()
        if key ~= nil then
            appendContainer(key:getContainer())
        end
        return entries
    end

    local function collectDeviceMedia(vehicle)
        local devices, seenDevices = {}, {}
        local function appendDevice(deviceData)
            if deviceData ~= nil and not seenDevices[deviceData] then
                seenDevices[deviceData] = true
                if deviceData:hasMedia() then
                    devices[#devices + 1] = deviceData
                end
            end
        end

        for partIndex = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(partIndex)
            appendDevice(part:getDeviceData())
            local item = part:getInventoryItem()
            if item ~= nil and instanceof(item, "Radio") then
                appendDevice(item:getDeviceData())
            end
        end
        return devices
    end

    local function dropContainerItems(entries, square)
        for _, entry in ipairs(entries) do
            entry.container:Remove(entry.item)
            sendRemoveItemFromContainer(entry.container, entry.item)
            square:AddWorldInventoryItem(entry.item, 0.5, 0.5, 0)
        end
    end

    local function dropDeviceMedia(devices, square)
        for _, deviceData in ipairs(devices) do
            local container = ItemContainer.new()
            deviceData:removeMediaItem(container)
            local mediaItem = container:getItems():get(0)
            container:Remove(mediaItem)
            square:AddWorldInventoryItem(mediaItem, 0.5, 0.5, 0)
        end
        return #devices
    end

    local function sourceFailure(vehicle, player, target)
        if vehicle == nil then return "source-not-found" end
        local x, y, z = vehicle:getX(), vehicle:getY(), vehicle:getZ()
        if math.floor(z) ~= math.floor(player:getZ()) then
            return "source-out-of-range"
        end
        local dx, dy = x - player:getX(), y - player:getY()
        if dx * dx + dy * dy > 36 then
            return "source-out-of-range"
        end
        local sourceGeometry = Units.geometry(target.unit, x, y)
        if sourceGeometry.hullDistanceTiles > 6 then
            return "source-out-of-range"
        end

        for seat = 0, vehicle:getMaxPassengers() - 1 do
            if vehicle:getCharacter(seat) ~= nil then
                return "source-occupied"
            end
        end
        if vehicle:getVehicleTowing() ~= nil
                or vehicle:getVehicleTowedBy() ~= nil then
            return "source-towing"
        end
        return nil
    end

    local function playerHasLoadingRamp(player)
        return player:getInventory():containsTypeRecurse(
            C.RV_LOADING_RAMP_ITEM)
    end

    local function loadVehicle(player, args)
        local target, reason = resolveCargoTarget(player, args)
        if not target then return false, reason end
        logResolvedTarget("load", target)
        if not playerHasLoadingRamp(player) then
            return false, C.RV_FLATCAR_NOTICE_LOADING_RAMP_REQUIRED
        end

        local vehicleId = C.finiteInteger(args.vehicleId)
        local vehicle = vehicleId ~= nil and getVehicleById(vehicleId) or nil
        if vehicle == nil then return false, "source-not-found" end
        local square = vehicle:getSquare()
        if square == nil then return false, "source-not-found" end
        reason = sourceFailure(vehicle, player, target)
        if reason ~= nil then return false, reason end

        local vehicleScript = vehicle:getScriptName()
        local flatcar = target.flatcar
        if not CargoCatalog.fits(flatcar.cars, vehicleScript) then
            return false, "deck-full"
        end

        local state = State.capture(vehicle)
        local visual = CargoCatalog.captureVisual(vehicle)
        local map = mapData()
        local cargoId = map.nextCargoId
        local items = collectContainerItems(vehicle)
        local devices = collectDeviceMedia(vehicle)
        dropContainerItems(items, square)
        local droppedMedia = dropDeviceMedia(devices, square)
        vehicle:permanentlyRemove()

        flatcar.cars[#flatcar.cars + 1] = {
            cargoId = cargoId,
            vehicleScript = vehicleScript,
            center = 0,
            state = state,
            visual = visual,
        }
        map.nextCargoId = cargoId + 1
        CargoCatalog.layout(flatcar.cars)

        broadcastFlatcar(target.key, flatcar)
        CargoCatalog.debug(
            "server load committed unitId=%s cargoId=%s sourceVehicleId=%s script=%s parts=%d droppedItems=%d",
            target.key, tostring(cargoId), tostring(vehicleId), vehicleScript,
            #state.parts, #items + droppedMedia)
        return true
    end

    local function unloadVehicle(player, args)
        local target, reason = resolveCargoTarget(player, args)
        if not target then return false, reason end
        logResolvedTarget("unload", target)
        if not playerHasLoadingRamp(player) then
            return false, C.RV_FLATCAR_NOTICE_LOADING_RAMP_REQUIRED
        end

        local cargoId = C.finiteInteger(args.cargoId)
        if cargoId == nil then return false, "cargo-not-found" end
        local cars = target.flatcar.cars
        local cargoIndex
        for index, car in ipairs(cars) do
            if car.cargoId == cargoId then
                cargoIndex = index
                break
            end
        end
        if cargoIndex == nil then return false, "cargo-not-found" end
        local cargo = cars[cargoIndex]
        local pose = Placement.findUnloadPose(target.cell, player,
            target.geometry, cargo.vehicleScript)
        if pose == nil then return false, "unload-blocked" end
        local spawned, vehicleOrReason = Placement.spawn(target.cell,
            cargo.vehicleScript, pose, cargo.state)
        if not spawned then
            return false, vehicleOrReason
        end

        table.remove(cars, cargoIndex)
        if #cars > 0 then CargoCatalog.layout(cars) end
        broadcastFlatcar(target.key, target.flatcar)
        CargoCatalog.debug(
            "server unload committed unitId=%s cargoId=%s newVehicleId=%s script=%s parts=%d position=(%.3f,%.3f,%.3f)",
            target.key, tostring(cargo.cargoId),
            tostring(vehicleOrReason:getId()),
            cargo.vehicleScript, vehicleOrReason:getPartCount(),
            pose.x, pose.y, pose.z)
        return true
    end

    local Service = {}
    function Service.handle(player, args)
        if type(args) ~= "table" then return false, "invalid-request" end
        CargoCatalog.debug("server request operation=%s unitId=%s",
            tostring(args.operation), tostring(args.unitId))
        if args.operation == "snapshot" then return snapshot(player) end
        if args.operation == "convert" then return convert(player, args) end
        if args.operation == "load" then return loadVehicle(player, args) end
        if args.operation == "unload" then return unloadVehicle(player, args) end
        return false, "invalid-operation"
    end

    return Service
end
