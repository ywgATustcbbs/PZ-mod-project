require "Items/ProceduralDistributions"

local INDUSTRIAL_WATER_PUMP = "RailroaderRV.WaterPumpIndustrial"
local LOOT_TABLES = {
	"GarageTools",
	"CrateTools",
	"ToolStoreTools",
	"ArmyStorageElectronics",
	"EngineerTools",
	"ToolFactoryTools",
}

local function addIndustrialWaterPump()
	for _, tableName in ipairs(LOOT_TABLES) do
		local items = ProceduralDistributions.list[tableName].items
		table.insert(items, INDUSTRIAL_WATER_PUMP)
		table.insert(items, 0.1)
	end
end

Events.OnPreDistributionMerge.Add(addIndustrialWaterPump)
