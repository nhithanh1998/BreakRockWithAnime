--!strict
-- IndexConfig: the Index (collection book). Every zone lists what its trees can drop (from
-- ZoneDrops: each material of its trees + its heroes); an item counts as FOUND once the player has
-- ever obtained it (selling it later doesn't undo that). Heroes count by their plain hero: a
-- "Diamond Huge Sling Scout" finds "Sling Scout".
-- Finding enough of a zone unlocks its rewards (Rewards below), claimed in the Index window.
-- IndexService on the server, IndexUI on the client.
--
-- Rewards[zone] = list of milestones:
--   Need    = share of the zone's items to find (0.5 = half, 1 = all of them)
--   Rewards = what it gives (same format as DailyRewardConfig: Money / Hero / Fertilizer / Fruit /
--             Material / Potion). The first reward is the big picture on its card.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZoneDrops = require(Shared:WaitForChild("ZoneDrops"))
local ZoneConfig = require(Shared:WaitForChild("ZoneConfig"))
local TreeConfig = require(Shared:WaitForChild("TreeConfig"))
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))

export type Reward = DailyRewardConfig.Reward

export type Milestone = {
	Need: number,
	Rewards: { Reward },
}

export type Entry = {
	Stack: string, -- "Anime:<hero>" or a material key (the stack names ChestService / ItemDisplay use)
	IsHero: boolean,
	Name: string,
	Rarity: string,
	Chance: number, -- 0..1 per felled tree in this zone (base, without luck)
}

local IndexConfig = {}

IndexConfig.HeroPrefix = "Anime:"
IndexConfig.FoundFolder = "IndexFound" -- player.IndexFound.<stack> (BoolValue) = found
IndexConfig.ClaimedPrefix = "IndexClaimed_" -- player attribute IndexClaimed_<zone> = bit mask of claimed milestones

IndexConfig.Rewards = {
	[1] = {
		{ Need = 0.5, Rewards = { { Kind = "Potion", Id = "HeroLuck", Amount = 2 }, { Kind = "Money", Amount = 2500 } } },
		{ Need = 1, Rewards = { { Kind = "Potion", Id = "ChopDamage", Amount = 3 }, { Kind = "Potion", Id = "Material", Amount = 2 }, { Kind = "Fertilizer", Amount = 2 } } },
	},
	[2] = {
		{ Need = 0.5, Rewards = { { Kind = "Potion", Id = "ChopSpeed", Amount = 2 }, { Kind = "Money", Amount = 25000 } } },
		{ Need = 1, Rewards = { { Kind = "Potion", Id = "MutationLuck", Amount = 3 }, { Kind = "Potion", Id = "SizeLuck", Amount = 3 }, { Kind = "Fertilizer", Amount = 5 } } },
	},
} :: { [number]: { Milestone } }

-- Zones that have an Index page, in order.
function IndexConfig.Zones(): { number }
	local list = {}
	for zone in ZoneDrops.Zones do
		table.insert(list, zone)
	end
	table.sort(list)
	return list
end

function IndexConfig.ZoneName(zone: number): string
	local info = ZoneConfig.Get(zone)
	return if info then info.Name else ZoneDrops.GetZone(zone).Name
end

local cache: { [number]: { Entry } } = {}

-- Everything a zone's trees can drop: materials first, then heroes, rarest last within each.
function IndexConfig.Items(zone: number): { Entry }
	local cached = cache[zone]
	if cached then
		return cached
	end
	local def = ZoneDrops.Zones[zone]
	local list: { Entry } = {}
	if not def then
		cache[zone] = list
		return list
	end
	local materials: { [string]: number } = {}
	for _, tree in def.Trees do
		for _, entry in tree.Drops do
			if TreeConfig.Materials[entry.Item] then
				materials[entry.Item] = math.max(materials[entry.Item] or 0, entry.Chance)
			end
		end
	end
	for key, chance in materials do
		local m = TreeConfig.Materials[key]
		table.insert(list, { Stack = key, IsHero = false, Name = m.Name, Rarity = m.Rarity, Chance = math.min(1, chance) })
	end
	local heroes = def.Heroes or {}
	local total = 0
	for _, h in heroes do
		total += h.Weight
	end
	local heroChance = ZoneConfig.GetBase(zone, "HeroChance") or 0
	for _, h in heroes do
		local hero = TreeConfig.GetHero(h.Item)
		if hero then
			table.insert(list, {
				Stack = IndexConfig.HeroPrefix .. hero.Name,
				IsHero = true,
				Name = hero.Name,
				Rarity = hero.Rarity,
				Chance = if total > 0 then heroChance * h.Weight / total else 0,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.IsHero ~= b.IsHero then
			return not a.IsHero
		end
		if a.Chance ~= b.Chance then
			return a.Chance > b.Chance
		end
		return a.Name < b.Name
	end)
	cache[zone] = list
	return list
end

-- How many items of the zone count as needed for a milestone.
function IndexConfig.Needed(zone: number, milestone: Milestone): number
	local count = #IndexConfig.Items(zone)
	return math.clamp(math.ceil(count * milestone.Need - 1e-9), 1, math.max(1, count))
end

-- The index stack an obtained item counts as: heroes by their plain name, materials by key.
-- `folder` is "Heroes" or "Inventory" (the player folders ChestService adds to).
function IndexConfig.StackFor(folder: string, itemName: string, splitVariant: (string) -> string): string?
	if folder == "Heroes" then
		return IndexConfig.HeroPrefix .. splitVariant(itemName)
	elseif folder == "Inventory" and TreeConfig.Materials[itemName] then
		return itemName
	end
	return nil
end

function IndexConfig.IsClaimed(mask: number, index: number): boolean
	return bit32.btest(mask, bit32.lshift(1, index - 1))
end

function IndexConfig.SetClaimed(mask: number, index: number): number
	return bit32.bor(mask, bit32.lshift(1, index - 1))
end

-- Found count of a zone for a player (works on the client too: the folder replicates).
function IndexConfig.FoundIn(player: Player, zone: number): (number, number)
	local folder = player:FindFirstChild(IndexConfig.FoundFolder)
	local found = 0
	local items = IndexConfig.Items(zone)
	for _, e in items do
		if folder and folder:FindFirstChild(e.Stack) then
			found += 1
		end
	end
	return found, #items
end

function IndexConfig.ClaimedMask(player: Player, zone: number): number
	local mask = player:GetAttribute(IndexConfig.ClaimedPrefix .. tostring(zone))
	return if typeof(mask) == "number" then mask else 0
end

-- Milestones of the zone the player can claim right now.
function IndexConfig.Claimable(player: Player, zone: number): number
	local found = IndexConfig.FoundIn(player, zone)
	local mask = IndexConfig.ClaimedMask(player, zone)
	local n = 0
	for i, m in IndexConfig.Rewards[zone] or {} do
		if not IndexConfig.IsClaimed(mask, i) and found >= IndexConfig.Needed(zone, m) then
			n += 1
		end
	end
	return n
end

return IndexConfig
