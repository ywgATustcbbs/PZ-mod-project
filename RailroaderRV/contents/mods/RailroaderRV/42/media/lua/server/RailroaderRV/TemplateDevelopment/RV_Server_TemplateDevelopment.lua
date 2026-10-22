-- Server-side template development commands.
return function(ctx)
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local stateReaders = {
    { "open", "isOpen" }, { "locked", "isLocked" },
    { "hoppable", "isHoppable" }, { "health", "getHealth" },
    { "maxHealth", "getMaxHealth" }, { "fuel", "getFuelAmount" },
    { "water", "getWaterAmount" }, { "uses", "getUses" },
}

local function isTransientObject(object)
    if ServerWorld.isPlayerObject(object) or ServerWorld.isVehicleObject(object) then
        return true
    end
    for _, className in ipairs({ "IsoZombie", "IsoAnimal", "IsoDeadBody",
        "IsoWorldInventoryObject" }) do
        if ServerUtil.classInstance(object, className) then return true end
    end
    return false
end

local function captureClass(object)
    local _, class = ServerUtil.invoke(object, "getClass")
    local name = string.gsub(tostring(class), "^class%s+", "")
    return string.match(name, "([^%.]+)$") or name
end

local function captureName(object)
    for _, method in ipairs({ "getName", "getObjectName", "getCustomName" }) do
        local ok, name = ServerUtil.invoke(object, method)
        if ok and name ~= nil then return tostring(name) end
    end
    return nil
end

local function captureState(object)
    local values = {}
    for index = 1, #stateReaders do
        local reader = stateReaders[index]
        local ok, value = ServerUtil.invoke(object, reader[2])
        if ok and value ~= nil then
            values[#values + 1] = reader[1] .. "=" .. tostring(value)
        end
    end
    return table.concat(values, ",")
end

local function saveTemplate(player, kind, position)
    local templateId = RoomTemplate.templateIdForDevelopmentKind(kind,
        SandboxVars.RailroaderRV.AllowEngineAreaBuilding)
    local anchor = TemplateGeometry.templateAnchorForWorld(
        position.x, position.y, position.z)
    local cell = ServerWorld.getCellForPlayer(player)
    local objectCount = 0

    print("[RailroaderRV][TemplateDevelopment] save kind=" .. kind
        .. " templateId=" .. templateId .. " origin="
        .. tostring(anchor.x) .. "," .. tostring(anchor.y) .. ","
        .. tostring(anchor.z))
    for z = 0, 1 do
        for y = RoomTemplate.MIN_Y, RoomTemplate.MAX_Y_EXCLUSIVE - 1 do
            for x = RoomTemplate.MIN_X, RoomTemplate.MAX_X_EXCLUSIVE - 1 do
                local square = ServerWorld.getSquare(cell,
                    anchor.x + x, anchor.y + y, anchor.z + z)
                if square then
                    local objects = ServerWorld.squareSnapshot(square)
                    for index = 1, #objects do
                        local object = objects[index]
                        if not isTransientObject(object) then
                            local northOk, north = ServerUtil.invoke(object,
                                "getNorth")
                            local directionOk, direction = ServerUtil.invoke(
                                object, "getDir")
                            local northValue
                            if northOk then northValue = north end
                            local directionValue
                            if directionOk then directionValue = direction end
                            objectCount = objectCount + 1
                            print("[RailroaderRV][TemplateDevelopment] object rel="
                                .. tostring(x) .. "," .. tostring(y) .. ","
                                .. tostring(z) .. " class=" .. captureClass(object)
                                .. " name=" .. tostring(captureName(object))
                                .. " sprite=" .. tostring(ServerWorld.getSpriteName(object))
                                .. " north=" .. tostring(northValue)
                                .. " direction=" .. tostring(directionValue)
                                .. " state=" .. captureState(object))
                        end
                    end
                end
            end
        end
    end
    print("[RailroaderRV][TemplateDevelopment] saved objects="
        .. tostring(objectCount))
    return true
end

local function handle(player, args)
    if not Constants.ENABLE_TEMPLATE_DEVELOPMENT then
        return false, "template-development-disabled"
    end

    local operation = args.operation
    local kind = args.kind
    local playerOk, positionOrReason = ctx.validateAuthoritativePlayer(player)
    if not playerOk then return false, positionOrReason end
    local permissionOk, permissionReason = ctx.validateGenerationPermission(player)
    if not permissionOk then return false, permissionReason end

    if operation == "save" then
        return saveTemplate(player, kind, positionOrReason)
    end

    if operation == "new" then
        return ctx.queueTemplateDevelopment(player, {
            operation = operation,
            kind = kind,
            northSouthLength = tonumber(args.northSouthLength),
            eastWestWidth = tonumber(args.eastWestWidth),
        })
    end
    if operation == "edit" then
        return ctx.queueTemplateDevelopment(player, {
            operation = operation, kind = kind,
        })
    end
end

return { handle = handle }
end
