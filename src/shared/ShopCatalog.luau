-- ShopCatalog: what the Robux shop hub sells (Gamepasses, Potions, Fruit Fertilizer, Hero Chest).
--
-- !! MOCK DATA !! Every price, id, hero pick and drop rate below is a placeholder so the shop UI
-- can be built and tested. Replace them before release:
--   * GamePassId / ProductId: create them on the Creator Dashboard and paste the ids.
--     An id of 0 means "not on sale yet": the UI shows "Soon" and the button can't be pressed.
--   * Robux: the price shown on the button (the real charge is whatever the Dashboard says).
--   * HeroChest.Pool: picked from HeroConfig for now; swap in the real exclusive heroes later.
-- Fruit Fertilizer packs already live in FruitConfig (Robux packs) and are only referenced here.

local ShopCatalog = {}

export type GamePass = {
	Id: string,
	Name: string,
	Desc: string,
	GamePassId: number,
	Robux: number,
	Icon: string,
}

export type PotionBundle = {
	Amount: number,
	ProductId: number,
	Robux: number,
}

export type ChestEntry = {
	Hero: string, -- HeroConfig hero Name
	Weight: number, -- relative weight, shown as a % in the UI
}

-- MOCK: gamepass list and prices.
ShopCatalog.GamePasses = {
	{ Id = "VIP", Name = "VIP", Desc = "+20% money, VIP chat tag", GamePassId = 0, Robux = 299, Icon = "" },
	{ Id = "DoubleMoney", Name = "x2 Money", Desc = "Double money from the stand", GamePassId = 0, Robux = 399, Icon = "" },
	{ Id = "ExtraHeroSlots", Name = "+3 Hero Slots", Desc = "Three more hero pads", GamePassId = 0, Robux = 249, Icon = "" },
	{ Id = "AutoChop", Name = "Auto Chop", Desc = "Your character chops by itself", GamePassId = 0, Robux = 199, Icon = "" },
	{ Id = "FastWalk", Name = "Fast Walk", Desc = "+30% walk speed", GamePassId = 0, Robux = 99, Icon = "" },
	{ Id = "LuckyCharm", Name = "Lucky Charm", Desc = "x1.5 hero luck forever", GamePassId = 0, Robux = 499, Icon = "" },
} :: { GamePass }

-- MOCK: every potion in PotionConfig sells in these bundles (Developer Products).
-- ProductIds are per potion: ShopCatalog.PotionProducts[potionId][amount].
ShopCatalog.PotionBundles = {
	{ Amount = 1, ProductId = 0, Robux = 29 },
	{ Amount = 3, ProductId = 0, Robux = 79 }, -- ~10% off
	{ Amount = 10, ProductId = 0, Robux = 229 }, -- ~20% off
} :: { PotionBundle }

ShopCatalog.PotionProducts = {
	HeroLuck = { [1] = 0, [3] = 0, [10] = 0 },
	Material = { [1] = 0, [3] = 0, [10] = 0 },
	ChopSpeed = { [1] = 0, [3] = 0, [10] = 0 },
	ChopDamage = { [1] = 0, [3] = 0, [10] = 0 },
	MutationLuck = { [1] = 0, [3] = 0, [10] = 0 },
	SizeLuck = { [1] = 0, [3] = 0, [10] = 0 },
	Money = { [1] = 0, [3] = 0, [10] = 0 },
} :: { [string]: { [number]: number } }

-- Fruit Fertilizer: the packs are FruitConfig.RobuxPacks (kept there so FruitUI keeps working).
ShopCatalog.FertilizerSource = "FruitConfig"

-- MOCK: the exclusive Hero Chest. Heroes borrowed from HeroConfig's list for now.
ShopCatalog.HeroChest = {
	Name = "Exclusive Hero Chest",
	Desc = "Only from this chest!",
	Robux = { [1] = 99, [3] = 279, [10] = 849 } :: { [number]: number },
	ProductIds = { [1] = 0, [3] = 0, [10] = 0 } :: { [number]: number },
	Pool = {
		{ Hero = "Sin Captain", Weight = 50 }, -- Rare
		{ Hero = "Water Swordman", Weight = 30 }, -- Epic
		{ Hero = "Star Brawler", Weight = 15 }, -- Legendary
		{ Hero = "Volleyball Rookie", Weight = 4 }, -- Mythic
		{ Hero = "Titan Lover", Weight = 1 }, -- Mythic
	} :: { ChestEntry },
}

-- Drop chance of each chest hero, 0-1 (for the odds list Roblox requires on paid random items).
function ShopCatalog.ChestOdds(): { [string]: number }
	local total = 0
	for _, e in ShopCatalog.HeroChest.Pool do
		total += e.Weight
	end
	local odds = {}
	for _, e in ShopCatalog.HeroChest.Pool do
		odds[e.Hero] = e.Weight / total
	end
	return odds
end

-- True when the item can be bought (a real id has been pasted in).
function ShopCatalog.OnSale(id: number): boolean
	return id ~= nil and id > 0
end

return ShopCatalog
