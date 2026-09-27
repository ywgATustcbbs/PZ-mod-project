-- Server-authoritative RV boundary service.
--
-- This module does not import or instantiate Railroader collider/body objects.
-- The AABB-based BoundaryGuard checks current player positions and returns an
-- out-of-bounds player to the validated RV entry destination. It is separate
-- from the TemplateProtectionRepair object queue and the RoofRefresh room path.
-- All guard work remains clipped to the owning RV's half-open 100x100xZ scope.

local function processIsClient()
    if type(isClient) ~= "function" then return false end
    local ok, value = pcall(isClient)
    return ok and value == true
end

local function processIsServer()
    if type(isServer) ~= "function" then return true end
    local ok, value = pcall(isServer)
    return ok and value == true
end

if processIsClient() and not processIsServer() then
    return {}
end

require "RailroaderRV/RV_Constants"
local Bitmap = require "RailroaderRV/RV_Bitmap"

RailroaderRV = RailroaderRV or {}
RailroaderRV.BoundaryServer = RailroaderRV.BoundaryServer or {}

local Boundary = RailroaderRV.BoundaryServer
local C = RailroaderRV.Constants
local OWNER = C.MOD_ID
local exactKeys = Bitmap.hasExactKeys

Boundary._states = Boundary._states or {}
Boundary._registered = Boundary._registered or {}
Boundary._builders = Boundary._builders or {}
Boundary._tick = Boundary._tick or 0


local ctx = {
    processIsServer = processIsServer,
    Bitmap = Bitmap,
    Boundary = Boundary,
    C = C,
    OWNER = OWNER,
    exactKeys = exactKeys,
}

require("RailroaderRV/RV_BoundaryServer_Geometry")(ctx)
require("RailroaderRV/RV_BoundaryServer_Objects")(ctx)
require("RailroaderRV/RV_BoundaryServer_Sweep")(ctx)

return Boundary
