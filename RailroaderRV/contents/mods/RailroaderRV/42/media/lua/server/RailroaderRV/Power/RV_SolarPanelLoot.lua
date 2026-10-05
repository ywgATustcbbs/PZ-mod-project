local ITEM_SOLAR_PANEL = "RailroaderRV.SolarPanel"

local TARGET_ROOMS = {
	garagestorage = true,
	storageunit = true,
	armystorage = true,
	oldarmy = true,
	armytent = true,
	warehouse = true,
}

local function onFillContainer(roomName, containerType, itemContainer)
	if isClient() then return end
	if not TARGET_ROOMS[roomName] then return end
	if containerType == "fridge" or containerType == "freezer" or containerType == "bin" then return end

	if ZombRand(100) < SandboxVars.RailroaderRV.SolarPanelLootChance then
		itemContainer:AddItem(ITEM_SOLAR_PANEL)
	end
end

Events.OnFillContainer.Add(onFillContainer)
