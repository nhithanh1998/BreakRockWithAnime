--!strict
-- StandStats: the ONE place a Farm Stand's stats are computed (server for selling, client for the UI).
--
--   Final = (LevelBase + Upgrades + Heroes + Fame) x Multiplier
--
--   StandStats.Breakdown(inputs) -> { [stat] = { Base, Upgrades, Heroes, Fame, Multiplier, Final } }
--   StandStats.Compute(inputs)   -> { [stat] = Final }
--   StandStats.PriceOf(materialId, priceMultiplier) -> money per item
--
-- Inputs: the stand, its level and (later steps) upgrade levels, keeper heroes' rarities and fame.
-- Each source is its own function below so adding one never touches the others.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StandConfig = require(Shared:WaitForChild("StandConfig"))
local MaterialConfig = require(Shared:WaitForChild("MaterialConfig"))
local HeroConfig = require(Shared:WaitForChild("HeroConfig"))
local StandLayoutConfig = require(Shared:WaitForChild("StandLayoutConfig"))
local StandUpgradeConfig = require(Shared:WaitForChild("StandUpgradeConfig"))

local StandStats = {}

StandStats.Stats = { "MaxStock", "CustomersPerMinute", "MaxItemsPerCustomer", "PriceMultiplier" }

export type Inputs = {
	StandId: string,
	Level: number,
	Upgrades: { [string]: number }?, -- upgrade id -> level (StandUpgradeConfig)
	Keepers: { [number]: string }?, -- keeper slot index -> hero name (rarity bonus)
	Fame: number?, -- fame points (FameConfig, step 9)
}

export type Line = { Base: number, Upgrades: number, Heroes: number, Fame: number, Multiplier: number, Final: number }

local function levelBase(inputs: Inputs, stat: string): number
	local def = StandConfig.Level(inputs.StandId, inputs.Level)
	if not def then
		return 0
	end
	if stat == "MaxStock" then
		return def.BaseMaxStock
	elseif stat == "CustomersPerMinute" then
		return def.BaseCustomersPerMinute
	elseif stat == "MaxItemsPerCustomer" then
		return def.BaseMaxItemsPerCustomer
	elseif stat == "PriceMultiplier" then
		return def.BasePriceMultiplier
	end
	return 0
end

-- Flat bonuses from bought upgrades (StandUpgradeConfig, Kind "Flat").
local function upgradeBonus(inputs: Inputs, stat: string): number
	local total = 0
	for id, level in inputs.Upgrades or {} do
		local def = StandUpgradeConfig.Get(id)
		if def and def.Effect.Kind == "Flat" and def.Effect.Stat == stat then
			total += (def.Effect.PerLevel or 0) * level
		end
	end
	return total
end

-- One keeper hero's bonus for a stat: StandConfig.RarityBonus by its rarity (an unlisted rarity uses
-- the closest lower listed one, by HeroConfig.GetRarityOrder).
function StandStats.KeeperBonus(hero: string, stat: string): number
	local def = HeroConfig.Get(hero)
	if not def then
		return 0
	end
	local entry = StandConfig.RarityBonus[def.Rarity]
	if not entry then
		local best, bestRank = nil, -1
		local rank = HeroConfig.GetRarityOrder(def.Rarity)
		for rarity, e in StandConfig.RarityBonus do
			local r = HeroConfig.GetRarityOrder(rarity)
			if r <= rank and r > bestRank then
				best, bestRank = e, r
			end
		end
		entry = best
	end
	return if entry then entry[stat] or 0 else 0
end

-- Flat bonuses from the keeper heroes (rarity), the star slot counting StarSlotBonus times.
local function heroBonus(inputs: Inputs, stat: string): number
	local layout = StandLayoutConfig.Stands[inputs.StandId]
	local level = layout and layout.Levels[inputs.Level]
	local star = level and level.StarKeeperSlot
	local total = 0
	for index, hero in inputs.Keepers or {} do
		local bonus = StandStats.KeeperBonus(hero, stat)
		total += if index == star then bonus * StandConfig.StarSlotBonus else bonus
	end
	return total
end

-- Flat bonuses from the stand's fame tier (step 9, FameConfig).
local function fameBonus(_inputs: Inputs, _stat: string): number
	return 0
end

-- Percentage multipliers from upgrades (Kind "Percent", e.g. Farm Side +30% customers). 1 = none.
local function multiplier(inputs: Inputs, stat: string): number
	local m = 1
	for id, level in inputs.Upgrades or {} do
		local def = StandUpgradeConfig.Get(id)
		if def and def.Effect.Kind == "Percent" and def.Effect.Stat == stat then
			m += (def.Effect.PerLevel or 0) * level
		end
	end
	return m
end

local function round(stat: string, value: number): number
	if stat == "PriceMultiplier" then
		return math.floor(value * 100 + 0.5) / 100
	elseif stat == "CustomersPerMinute" then
		return math.floor(value * 10 + 0.5) / 10
	end
	return math.floor(value)
end

function StandStats.Breakdown(inputs: Inputs): { [string]: Line }
	local out = {}
	for _, stat in StandStats.Stats do
		local line: Line = {
			Base = levelBase(inputs, stat),
			Upgrades = upgradeBonus(inputs, stat),
			Heroes = heroBonus(inputs, stat),
			Fame = fameBonus(inputs, stat),
			Multiplier = multiplier(inputs, stat),
			Final = 0,
		}
		line.Final = round(stat, (line.Base + line.Upgrades + line.Heroes + line.Fame) * line.Multiplier)
		out[stat] = line
	end
	return out
end

function StandStats.Compute(inputs: Inputs): { [string]: number }
	local out = {}
	for stat, line in StandStats.Breakdown(inputs) do
		out[stat] = line.Final
	end
	return out
end

-- A helper hero's carry per trip and walking speed (studs / s): StandConfig.Helper base + its rarity
-- bonus + the Helper Training upgrade (StandUpgradeConfig Kind "Helper", from `upgrades`).
function StandStats.HelperStats(hero: string, upgrades: { [string]: number }?): { Carry: number, Speed: number }
	local cfg = StandConfig.Helper
	local def = HeroConfig.Get(hero)
	local bonus = def and cfg.RarityBonus[def.Rarity]
	if def and not bonus then
		local bestRank = -1
		local rank = HeroConfig.GetRarityOrder(def.Rarity)
		for rarity, e in cfg.RarityBonus do
			local r = HeroConfig.GetRarityOrder(rarity)
			if r <= rank and r > bestRank then
				bonus, bestRank = e, r
			end
		end
	end
	local extraCarry, speedMult = 0, 1
	for id, level in upgrades or {} do
		local def = StandUpgradeConfig.Get(id)
		if def and def.Effect.Kind == "Helper" then
			extraCarry += (def.Effect.Carry or 0) * level
			speedMult += (def.Effect.Speed or 0) * level
		end
	end
	return {
		Carry = cfg.BaseCarry + (if bonus then bonus.Carry else 0) + extraCarry,
		Speed = cfg.BaseSpeed * (if bonus then bonus.Speed else 1) * speedMult,
	}
end

function StandStats.PriceOf(materialId: string, priceMultiplier: number): number
	local def = MaterialConfig.Get(materialId)
	if not def then
		return 0
	end
	return math.max(1, math.floor(def.BasePrice * priceMultiplier + 0.5))
end

return StandStats
