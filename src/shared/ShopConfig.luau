--!strict
-- ShopConfig: the shops in each plot's "Shops" folder (Models with a "Shop" attribute, built in Studio; each has
-- a "PromptPart" where ShopService puts the ProximityPrompt and an "NPCSpot" behind the counter).
--   "LumberAxe" -> Lumber Axe window: buy / equip axes. The equipped axe sets your click damage.
--                  Axes have a server-wide stock that refills every RestockInterval seconds, and an
--                  axe only shows up for sale once the player has unlocked its Zone (ZoneConfig).
-- Axe models for the shop pictures: ReplicatedStorage.Axes.<Model> (copies of Workspace.AxeCollection).

local ShopConfig = {}

ShopConfig.PromptDistance = 10 -- studs
ShopConfig.CloseDistance = 24 -- the window closes when you walk this far from the shop

ShopConfig.Shops = {
	LumberAxe = { ObjectText = "Lumber Axe", ActionText = "Buy Axes" },
	Feedback = { ObjectText = "Feedback", ActionText = "Send Feedback" },
} :: { [string]: { ObjectText: string, ActionText: string } }

-- Feedback stall ("Feedback" shop): players write feedback, FeedbackService saves it in the
-- DataStore below (one key per message). Read it with the snippet at the top of FeedbackService.
ShopConfig.Feedback = {
	DataStore = "GameFeedback_v1",
	Categories = { "Bug", "Idea", "Other" },
	MinLength = 5,
	MaxLength = 500,
	Cooldown = 60, -- seconds between two messages from the same player
	MaxPerSession = 5, -- messages a player can send per server visit
}

-- Heroes sold from the Inventory window (InventoryService) are worth their HeroConfig Sell price * this,
-- each. Heroes standing on any pad can't be sold (take them back first).
ShopConfig.HeroSellMultiplier = 1

export type AxeDef = {
	Model: string, -- name in ReplicatedStorage.Axes
	Name: string,
	Rarity: string, -- TreeConfig rarity (card colour)
	Price: number, -- Money
	Damage: number, -- click damage while equipped
	HeroBoost: number, -- a hero holding this axe deals Chop Damage x this (HeroUpgradeUI "Axe")
	Zone: number, -- the player must have unlocked this zone (UnlockedZones) to buy it
	Stock: { number }, -- { min, max } copies in stock after each restock (rolled per axe, server-wide)
	AxeImage: string?, -- uploaded icon ("rbxassetid://123" or "123"); empty = draw the 3D model
}

-- Shop order. Every player starts with StartAxe (1 copy).
-- Copies: an axe can be bought again for more copies (the "+1" on an owned card). Each copy can be
-- given to one hero pad (HeroSlotService); the player's own equipped axe doesn't use a copy.
ShopConfig.StartAxe = "WoodenAxe"
ShopConfig.Axes = {
	{ Model = "WoodenAxe", Name = "Wooden Axe", Rarity = "Common", Price = 0, Damage = 10, HeroBoost = 1, Zone = 1, Stock = { 99, 99 }, AxeImage = "" },
	{ Model = "StoneAxe", Name = "Stone Axe", Rarity = "Common", Price = 750, Damage = 15, HeroBoost = 1.1, Zone = 1, Stock = { 5, 8 }, AxeImage = "" },
	{ Model = "CopperAxe", Name = "Copper Axe", Rarity = "Uncommon", Price = 3000, Damage = 25, HeroBoost = 1.25, Zone = 1, Stock = { 3, 6 }, AxeImage = "" },
	{ Model = "IronAxe", Name = "Iron Axe", Rarity = "Uncommon", Price = 12000, Damage = 40, HeroBoost = 1.45, Zone = 1, Stock = { 2, 4 }, AxeImage = "" },
	{ Model = "GoldenAxe", Name = "Golden Axe", Rarity = "Rare", Price = 50000, Damage = 65, HeroBoost = 1.7, Zone = 1, Stock = { 1, 3 }, AxeImage = "" },
	{ Model = "EmeraldAxe", Name = "Emerald Axe", Rarity = "Rare", Price = 80000, Damage = 100, HeroBoost = 2, Zone = 2, Stock = { 1, 3 }, AxeImage = "" },
	{ Model = "InfernoAxe", Name = "Inferno Axe", Rarity = "Epic", Price = 350000, Damage = 160, HeroBoost = 2.5, Zone = 2, Stock = { 0, 2 }, AxeImage = "" },
	{ Model = "FrostbiteAxe", Name = "Frostbite Axe", Rarity = "Epic", Price = 1200000, Damage = 250, HeroBoost = 3.1, Zone = 2, Stock = { 0, 2 }, AxeImage = "" },
	{ Model = "VoidReaperAxe", Name = "Void Reaper Axe", Rarity = "Legendary", Price = 25000000, Damage = 400, HeroBoost = 4, Zone = 3, Stock = { 0, 1 }, AxeImage = "" },
	{ Model = "CelestialAxe", Name = "Celestial Axe", Rarity = "Mythic", Price = 100000000, Damage = 650, HeroBoost = 5.5, Zone = 3, Stock = { 0, 1 }, AxeImage = "" },
} :: { AxeDef }

-- Restock: every RestockInterval seconds (aligned to the clock, so every server restocks at the same
-- time) each axe's stock is rolled again from its Stock range. Buying one takes 1 from the stock for
-- everyone in the server. The stock lives in ReplicatedStorage.AxeStock.<Model> (IntValue) and the
-- next restock time (workspace:GetServerTimeNow()) in its "NextRestock" attribute.
ShopConfig.RestockInterval = 5 * 60

local byModel: { [string]: AxeDef } = {}
for _, axe in ShopConfig.Axes do
	-- "123" -> "rbxassetid://123", "" -> nil (the UI then draws ReplicatedStorage.Axes.<Model>)
	local image = axe.AxeImage and axe.AxeImage:gsub("^%s+", ""):gsub("%s+$", "")
	axe.AxeImage = if image == nil or image == "" then nil elseif image:match("^%d+$") then "rbxassetid://" .. image else image
	byModel[axe.Model] = axe
end

function ShopConfig.GetAxe(model: string): AxeDef?
	return byModel[model]
end

return ShopConfig
