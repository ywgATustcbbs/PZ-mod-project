-- Server-authoritative RV boundary service.
--
-- This module deliberately does not import or instantiate any Railroader
-- collider/body object.  It borrows only the useful shape of that solution:
-- keep a short-lived previous position, reject a swept transition at the
-- boundary, and correct current/next state together when recovery is needed.
-- The RV bitmap is the canonical geometry and every world operation is
-- clipped to the owning RV's half-open 100x100xZ scope.

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
