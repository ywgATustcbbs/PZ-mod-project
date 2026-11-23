local Cargo = {}

function Cargo.isEligible(animal)
    if not animal or animal:isDead() or animal:getHealth() <= 0 then
        return false
    end

    local animalType = animal:getAnimalType()
    if type(animalType) ~= "string" or animalType:sub(1, 3) == "rr_" then
        return false
    end

    local modData = animal:getModData()
    if modData.rrLoco == true or modData.rrWall == true then
        return false
    end

    local data = animal:getData()
    if animal:isOnHook() or animal:getVehicle() ~= nil
        or animal:getHutch() ~= nil or data:getAttachedPlayer() ~= nil
        or data:getAttachedTree() ~= nil then
        return false
    end

    local square = animal:getSquare()
    return square ~= nil and animal:isExistInTheWorld()
end

function Cargo.selectionIds(animal)
    local onlineId = isMultiplayer() and animal:getOnlineID() or nil
    local animalId = animal:getAnimalID()
    return onlineId, animalId
end

function Cargo.withinRadius(x1, y1, x2, y2, radius)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy <= radius * radius
end

function Cargo.label(animal)
    return animal:getFullName()
end

function Cargo.savedLabel(saved)
    if saved.customName ~= nil and saved.customName ~= "" then
        return saved.customName
    end

    local animalType = getText("IGUI_AnimalType_" .. saved.animalType)
    if saved.breed == nil or saved.breed == "" then
        return animalType
    end

    local breed = getText("IGUI_Breed_" .. saved.breed)
    return getText("IGUI_AnimalFullName", breed, animalType)
end

return Cargo
