local animalType = "rr_rv_flatcar_endpoint_marker"
local definitions = AnimalDefinitions

if not definitions.animals[animalType] then
    local animal = copyTable(definitions.animals.cow)
    local model = "RailroaderRV.RV_FlatcarEndpointMarkerAnchor"
    animal.bodyModel = model
    animal.bodyModelSkel = model
    animal.bodyModelHeadless = model
    animal.bodyModelSkelNoHead = model
    animal.modelscript = model
    animal.bodyModelFleece = nil
    animal.textureSkinned = nil
    animal.animset = "cow"
    animal.stages = { [animalType] = { ageToGrow = 365 } }
    animal.babyType = nil
    animal.minAge = 0
    animal.genes = {}
    for key, value in pairs(definitions.genome.cow.genes) do
        if value ~= "maxSize" then animal.genes[key] = value end
    end
    animal.minSize = 1
    animal.maxSize = 1
    animal.animalSize = 1
    animal.female = true
    animal.collidable = false
    animal.collisionSize = 0.1
    animal.shadoww, animal.shadowfm, animal.shadowbm = 0, 0, 0
    animal.idleSoundVolume = 0
    animal.idleSoundRadius = 0
    animal.breeds = {
        rv = { name = "rv", texture = "RR_BX40", textureMale = "RR_BX40" },
    }
    animal.group = animalType
    definitions.animals[animalType] = animal
    definitions.stages[animalType] = { stages = animal.stages }
    definitions.genome[animalType] = definitions.genome.cow
    definitions.breeds[animalType] = { breeds = animal.breeds }
end

local group = AttachedLocations.getGroup("Animal")
group:getOrCreateLocation("RVFlatcarEndpointStart"):setAttachmentName(
    "RVFlatcarEndpointStart")
group:getOrCreateLocation("RVFlatcarEndpointEnd"):setAttachmentName(
    "RVFlatcarEndpointEnd")
