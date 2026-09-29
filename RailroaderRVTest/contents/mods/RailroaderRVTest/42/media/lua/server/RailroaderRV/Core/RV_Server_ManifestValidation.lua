-- RV_Server: ManifestValidation responsibilities.
return function(ctx)
local DevSaveSchemaGate = require("RailroaderRV/Core/RV_DevSaveSchemaGate")
local OWNER = ctx.OWNER
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local ServerUtil = ctx.ServerUtil
local requireCurrentManifest

DevSaveSchemaGate.configureManifest({
    OWNER = OWNER,
    Constants = Constants,
    Boundary = Boundary,
    Bitmap = Bitmap,
    Layout = Layout,
    RegionSlots = RegionSlots,
    ServerUtil = ServerUtil,
})

requireCurrentManifest = function(manifest)
    if not DevSaveSchemaGate.isReady() then error(Constants.INVALID_RV_DATA) end
    return manifest
end

ctx.currentManifestValid = function()
    return DevSaveSchemaGate.isReady()
end
ctx.requireCurrentManifest = requireCurrentManifest
end
