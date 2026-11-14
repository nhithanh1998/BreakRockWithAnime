--!strict
-- StandConfig: what each Farm Stand sells and how well, per level. All numbers live here; a new level
-- or a new stand is a new entry (plus its models / markers, StandLayoutConfig).
--
-- Stand stats (StandStats computes them, server and UI use the same function):
--   MaxStock             how many materials the stand holds
--   CustomersPerMinute   how often a customer walks up (with a bit of randomness, CustomerJitter)
--   MaxItemsPerCustomer  a customer buys 1..this many items (as long as there is stock)
--   PriceMultiplier      money per item = material base price (MaterialConfig) x this
-- Final = (level base + upgrades + keeper heroes + fame) x multipliers.

local StandConfig = {}

export type LevelDef = {
	Name: string, -- shown on the billboard
	BaseMaxStock: number,
	BaseCustomersPerMinute: number,
	BaseMaxItemsPerCustomer: number,
	BasePriceMultiplier: number,
	UpgradeCost: number?, -- money to go from the level before to this one (nil for level 1)
}

export type StandDef = {
	Name: string,
	Levels: { LevelDef },
}

StandConfig.CustomerJitter = 0.3 -- each wait between customers is (60 / CPM) x random(1 - j, 1 + j)
StandConfig.OutOfStockToastCooldown = 30 -- seconds between two "out of stock" toasts
StandConfig.SaleFxMaxCoins = 6 -- coins that fly to the owner per sale (client FX)

-- VIP customers (only at levels with a VIP lane): rarer, buy more, pay more.
StandConfig.Vip = {
	Chance = 0.1, -- of each customer
	ItemsMultiplier = 2, -- x MaxItemsPerCustomer (they buy at least half of that)
	PriceMultiplier = 1.5, -- x the money
}

-- Customer NPCs (CustomerClient, client only: the sale is decided on the server).
StandConfig.Customers = {
	WalkSpeed = 11, -- studs / s
	ServeTime = 1.2, -- seconds at the counter
	MaxVisible = 20, -- NPCs per stand on one client; above that a sale only shows its "+$"
	Templates = 8, -- different customer looks (R15, made once on the server)
}

-- Stand Keeper heroes: each hero on a keeper pad adds these flat bonuses, by rarity (the higher the
-- rarity, the more: HeroConfig.GetRarityOrder). A rarity missing here falls back to the closest lower one.
StandConfig.RarityBonus = {
	Common = { CustomersPerMinute = 1, MaxStock = 5 },
	Uncommon = { CustomersPerMinute = 2, MaxStock = 10 },
	Rare = { CustomersPerMinute = 4, MaxStock = 20 },
	Epic = { CustomersPerMinute = 7, MaxStock = 35 },
	Legendary = { CustomersPerMinute = 12, MaxStock = 60 },
	Mythic = { CustomersPerMinute = 20, MaxStock = 100 },
} :: { [string]: { [string]: number } }
-- The star keeper slot (StandLayoutConfig StarKeeperSlot, the podium of the grand market) multiplies
-- its hero's bonus by this.
StandConfig.StarSlotBonus = 1.5
-- How often a keeper hero waves at customers (seconds, random between Min and Max).
StandConfig.KeeperWave = { Min = 6, Max = 12, AnimationId = "rbxassetid://507770239" }

-- Helpers: heroes on the 3 helper pads next to the chest carry materials from the chest to the
-- stand by themselves (StandService). Each trip: walk to the chest, pick up CarryPerTrip, walk the
-- helper path to the stand, drop them into the stock (only up to MaxStock), go again. They rest on
-- their pad when the chest is empty or the stand is full, and start again once the stock drops
-- below ResumeBelow x MaxStock.
StandConfig.Helper = {
	BaseCarry = 8, -- materials per trip
	BaseSpeed = 16, -- studs per second (the route chest -> stand is about 140 studs)
	PickupTime = 0.8, -- seconds at the chest
	DropTime = 0.8, -- seconds at the stand
	ResumeBelow = 0.9, -- a resting helper starts again when stock < this x MaxStock
	Stagger = 1.5, -- seconds between the helpers' starts (helper N waits (N - 1) x this)
	-- By rarity: extra materials per trip and a speed multiplier.
	RarityBonus = {
		Common = { Carry = 0, Speed = 1 },
		Uncommon = { Carry = 1, Speed = 1.05 },
		Rare = { Carry = 2, Speed = 1.1 },
		Epic = { Carry = 4, Speed = 1.2 },
		Legendary = { Carry = 7, Speed = 1.35 },
		Mythic = { Carry = 12, Speed = 1.5 },
	} :: { [string]: { Carry: number, Speed: number } },
}

-- Restock mat (the "RestockMat" marker behind the stand): standing on it moves carried materials
-- into the stand's stock, RestockPerTick every RestockInterval seconds, up to MaxStock.
StandConfig.Restock = {
	PerTick = 4,
	Interval = 0.15, -- seconds
	Reach = 1.5, -- studs outside the mat's edge that still count as standing on it
	Height = 6, -- studs above the mat the player's root may be
	FullToastCooldown = 8, -- seconds between two "stand is full" toasts
}

StandConfig.Stands = {
	FarmStand = {
		Name = "Farm Stand",
		Levels = {
			{ Name = "Farm Stand", BaseMaxStock = 40, BaseCustomersPerMinute = 20, BaseMaxItemsPerCustomer = 2, BasePriceMultiplier = 1 },
			{ Name = "Farm Stand", BaseMaxStock = 80, BaseCustomersPerMinute = 30, BaseMaxItemsPerCustomer = 3, BasePriceMultiplier = 1.1, UpgradeCost = 500 },
			{ Name = "Farm Stand", BaseMaxStock = 150, BaseCustomersPerMinute = 45, BaseMaxItemsPerCustomer = 4, BasePriceMultiplier = 1.25, UpgradeCost = 2500 },
			{ Name = "Farm Market", BaseMaxStock = 300, BaseCustomersPerMinute = 65, BaseMaxItemsPerCustomer = 5, BasePriceMultiplier = 1.45, UpgradeCost = 12000 },
			{ Name = "Grand Farm Market", BaseMaxStock = 600, BaseCustomersPerMinute = 90, BaseMaxItemsPerCustomer = 6, BasePriceMultiplier = 1.7, UpgradeCost = 60000 },
		},
	},
} :: { [string]: StandDef }

function StandConfig.Level(standId: string, level: number): LevelDef?
	local stand = StandConfig.Stands[standId]
	return stand and stand.Levels[level]
end

function StandConfig.MaxLevel(standId: string): number
	local stand = StandConfig.Stands[standId]
	return if stand then #stand.Levels else 0
end

return StandConfig
