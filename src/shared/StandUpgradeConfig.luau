--!strict
-- StandUpgradeConfig: the upgrades bought on the Farm Stand's upgrade pads (UpgradePad_<Id> markers;
-- which pads a level has: StandLayoutConfig UpgradePads). Each has levels with rising costs and a MAX.
-- A new upgrade = a new entry here + its pad in the level models.
--
-- Effect kinds:
--   Flat     +PerLevel x level to a stand stat (StandStats "Upgrades" column)
--   Percent  x (1 + PerLevel x level) on a stand stat (StandStats "Multiplier" column)
--   Carry    +PerLevel x level to the owner's CarryCapacity (player attribute "CarryBonus")
--   Helper   every helper carries +Carry x level more per trip and walks (1 + Speed x level) faster

local StandUpgradeConfig = {}

export type Effect = {
	Kind: string, -- "Flat" | "Percent" | "Carry" | "Helper"
	Stat: string?, -- stand stat for Flat / Percent
	PerLevel: number?,
	Carry: number?, -- Helper
	Speed: number?, -- Helper
}

export type UpgradeDef = {
	Name: string,
	Desc: string, -- one line for the pad / window ("+30% customers per level")
	Costs: { number }, -- cost of level 1, 2, ... (MaxLevel = #Costs)
	Effect: Effect,
	Color: Color3, -- pad / window accent
}

StandUpgradeConfig.Upgrades = {
	FarmSide = {
		Name = "Farm Side",
		Desc = "+30% customers per level",
		Costs = { 300, 1200, 4000, 12000, 35000 },
		Effect = { Kind = "Percent", Stat = "CustomersPerMinute", PerLevel = 0.3 },
		Color = Color3.fromRGB(90, 200, 110),
	},
	FarmSign = {
		Name = "Farm Sign",
		Desc = "+1 item per customer per level",
		Costs = { 500, 2500, 9000, 30000 },
		Effect = { Kind = "Flat", Stat = "MaxItemsPerCustomer", PerLevel = 1 },
		Color = Color3.fromRGB(230, 90, 70),
	},
	MaterialPrice = {
		Name = "Material Price +",
		Desc = "+10% sell price per level",
		Costs = { 150, 400, 900, 2000, 4500, 9000, 18000, 35000, 70000, 140000 },
		Effect = { Kind = "Flat", Stat = "PriceMultiplier", PerLevel = 0.1 },
		Color = Color3.fromRGB(250, 200, 60),
	},
	BiggerShelf = {
		Name = "Bigger Shelf",
		Desc = "+25% max stock per level",
		Costs = { 200, 800, 2500, 7000, 18000, 45000 },
		Effect = { Kind = "Percent", Stat = "MaxStock", PerLevel = 0.25 },
		Color = Color3.fromRGB(176, 120, 64),
	},
	CarryCapacity = {
		Name = "Carry Capacity",
		Desc = "+10 materials you can carry per level",
		Costs = { 100, 300, 800, 2000, 5000, 12000, 30000, 75000 },
		Effect = { Kind = "Carry", PerLevel = 10 },
		Color = Color3.fromRGB(90, 160, 240),
	},
	HelperTraining = {
		Name = "Helper Training",
		Desc = "Helpers carry +2 and walk 10% faster per level",
		Costs = { 600, 2500, 8000, 25000, 70000 },
		Effect = { Kind = "Helper", Carry = 2, Speed = 0.1 },
		Color = Color3.fromRGB(170, 100, 230),
	},
} :: { [string]: UpgradeDef }

-- How close (studs) the player must be to an upgrade pad to buy (server check) / open its window.
StandUpgradeConfig.PadReach = 7

function StandUpgradeConfig.Get(id: string): UpgradeDef?
	return StandUpgradeConfig.Upgrades[id]
end

function StandUpgradeConfig.MaxLevel(id: string): number
	local def = StandUpgradeConfig.Upgrades[id]
	return if def then #def.Costs else 0
end

-- Cost of the next level, or nil at MAX.
function StandUpgradeConfig.NextCost(id: string, level: number): number?
	local def = StandUpgradeConfig.Upgrades[id]
	return if def then def.Costs[level + 1] else nil
end

return StandUpgradeConfig
