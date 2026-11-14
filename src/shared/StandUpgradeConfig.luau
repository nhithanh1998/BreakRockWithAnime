--!strict
-- StandUpgradeConfig: the Farm Stand's upgrades. Board = true ones are buttons on the stand's billboard
-- (BoardOrder); the others are bought on upgrade pads (UpgradePad_<Id> markers; which pads a level has:
-- StandLayoutConfig UpgradePads). Each has levels with rising costs and a MAX.
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
	Board: boolean?, -- bought with a button on the stand's billboard (near the stand), not on a pad
}

-- n costs: base x growth^(level - 1), rounded to 2 significant digits.
local function costs(base: number, growth: number, n: number): { number }
	local out = {}
	for i = 1, n do
		local c = base * growth ^ (i - 1)
		local step = 10 ^ math.max(0, math.floor(math.log10(c)) - 1)
		out[i] = math.floor(c / step + 0.5) * step
	end
	return out
end

StandUpgradeConfig.Upgrades = {
	Capacity = {
		Name = "Capacity",
		Desc = "+23 max stock per level",
		Costs = costs(100, 1.45, 20),
		Effect = { Kind = "Flat", Stat = "MaxStock", PerLevel = 23 },
		Color = Color3.fromRGB(235, 140, 50),
		Board = true,
	},
	Fame = {
		Name = "Fame",
		Desc = "+2 customers a minute per level",
		Costs = costs(150, 1.45, 20),
		Effect = { Kind = "Flat", Stat = "CustomersPerMinute", PerLevel = 2 },
		Color = Color3.fromRGB(170, 90, 230),
		Board = true,
	},
} :: { [string]: UpgradeDef }

-- The buttons on the stand's billboard, left to right (upgrades with Board = true).
StandUpgradeConfig.BoardOrder = { "Capacity", "Fame" }

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
