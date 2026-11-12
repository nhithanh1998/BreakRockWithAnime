--!strict
-- ShopConfig: the shops in Workspace.Shops (Models with a "Shop" attribute, built in Studio; each has
-- a "PromptPart" where ShopService puts the ProximityPrompt and an "NPCSpot" behind the counter).
--   "Sell"      -> Sell window: sell materials (and heroes you pick yourself) for Money.
--                  "Select All" only selects materials.
--   "LumberAxe" -> Lumber Axe window: buy / equip axes. The equipped axe sets your click damage.
-- Axe models for the shop pictures: ReplicatedStorage.Axes.<Model> (copies of Workspace.AxeCollection).

local ShopConfig = {}

ShopConfig.PromptDistance = 10 -- studs
ShopConfig.CloseDistance = 24 -- the window closes when you walk this far from the shop

ShopConfig.Shops = {
	Sell = { ObjectText = "Sell", ActionText = "Sell Items" },
	LumberAxe = { ObjectText = "Lumber Axe", ActionText = "Buy Axes" },
} :: { [string]: { ObjectText: string, ActionText: string } }

-- Heroes sold in the Sell window are worth MinePower * this, each. Heroes standing on a pad
-- can't be sold (take them back first).
ShopConfig.HeroSellMultiplier = 1

export type AxeDef = {
	Model: string, -- name in ReplicatedStorage.Axes
	Name: string,
	Rarity: string, -- TreeConfig rarity (card colour)
	Price: number, -- Money
	Damage: number, -- click damage while equipped
}

-- Shop order. Every player starts with StartAxe.
ShopConfig.StartAxe = "WoodenAxe"
ShopConfig.Axes = {
	{ Model = "WoodenAxe", Name = "Wooden Axe", Rarity = "Common", Price = 0, Damage = 10 },
	{ Model = "StoneAxe", Name = "Stone Axe", Rarity = "Common", Price = 750, Damage = 15 },
	{ Model = "CopperAxe", Name = "Copper Axe", Rarity = "Uncommon", Price = 3000, Damage = 25 },
	{ Model = "IronAxe", Name = "Iron Axe", Rarity = "Uncommon", Price = 12000, Damage = 40 },
	{ Model = "GoldenAxe", Name = "Golden Axe", Rarity = "Rare", Price = 50000, Damage = 65 },
	{ Model = "EmeraldAxe", Name = "Emerald Axe", Rarity = "Rare", Price = 200000, Damage = 100 },
	{ Model = "InfernoAxe", Name = "Inferno Axe", Rarity = "Epic", Price = 1000000, Damage = 160 },
	{ Model = "FrostbiteAxe", Name = "Frostbite Axe", Rarity = "Epic", Price = 5000000, Damage = 250 },
	{ Model = "VoidReaperAxe", Name = "Void Reaper Axe", Rarity = "Legendary", Price = 25000000, Damage = 400 },
	{ Model = "CelestialAxe", Name = "Celestial Axe", Rarity = "Mythic", Price = 100000000, Damage = 650 },
} :: { AxeDef }

local byModel: { [string]: AxeDef } = {}
for _, axe in ShopConfig.Axes do
	byModel[axe.Model] = axe
end

function ShopConfig.GetAxe(model: string): AxeDef?
	return byModel[model]
end

return ShopConfig
