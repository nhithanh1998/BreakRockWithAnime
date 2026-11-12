--!strict
-- ZoneDrops: which trees grow in each zone, and what EACH tree drops.
--
-- A plot's zone is its "Zone" attribute (the same number that picks the tree models from
-- ReplicatedStorage.Trees.Map<Zone>, falling back to Map1).
--
-- Every zone lists its trees in `Trees`. Each tree:
--   Name   = display name (only for reading the config / warnings)
--   Models = tree model names -> size multiplier. A multiplier scales Chance (max 100%; a
--            Chance of 1 stays 1) and Min/Max (at least 1) of every drop, so saplings give less
--            and old trees give more.
--   Drops  = what THIS tree drops (written for a normal-size tree, multiplier 1):
--     Item    = a key in TreeConfig.Materials (e.g. "OakBark") or a hero Name from HeroConfig.luau
--     Chance  = 0..1, rolled on its own every time the tree is felled (0.25 = 25%)
--     Min/Max = how many drop when it hits (default 1)
--
-- Only models listed in a zone's Trees grow in that zone, and a tree only drops its own list:
-- there is no zone-wide drop list any more. Zones without an entry use zone 1.
--
-- Heroes (optional, per zone):
--   HeroChance = 0..1, chance that a felled tree drops ONE hero (any tree type). The player's
--                "HeroLuck" attribute multiplies it (default 1; for the skill tree / boosts).
--   Heroes     = which hero it is, picked by Weight (bigger = more common). The chance shown on a
--                dropped hero is HeroChance * luck * its weight share.
--
-- New item? Add it to TreeConfig.Materials (or HeroConfig.Heroes) first, then list it here.

local TreeConfig = require(script.Parent:WaitForChild("TreeConfig"))

type DropEntry = TreeConfig.DropEntry

export type HeroEntry = {
	Item: string, -- hero Name from HeroConfig
	Weight: number,
}

export type TreeDef = {
	Name: string,
	Models: { [string]: number },
	Drops: { DropEntry },
}

export type ZoneDef = {
	Name: string,
	Trees: { [string]: TreeDef },
	HeroChance: number?,
	Heroes: { HeroEntry }?,
}

local ZoneDrops = {}

-- The usual three sizes of a tree family ("Oak" -> OakSapling / OakTree / OldOakTree).
local function sizes(family: string): { [string]: number }
	return {
		[family .. "Sapling"] = 0.5,
		[family .. "Tree"] = 1,
		["Old" .. family .. "Tree"] = 1.5,
	}
end

-- Green Wood heroes, reused by Orchard Valley for now.
local GREEN_WOOD_HEROES: { HeroEntry } = {
	{ Item = "Sling Pirate", Weight = 40 }, -- Common
	{ Item = "Taijutsu Ninja", Weight = 40 }, -- Common
	{ Item = "Uzumaki Kid", Weight = 15 }, -- Uncommon
	{ Item = "Copy Ninja", Weight = 4 }, -- Rare
	{ Item = "Perfect Bioform", Weight = 1 }, -- Epic
}

ZoneDrops.Zones = {
	[1] = {
		Name = "Green Wood",
		Trees = {
			Oak = {
				Name = "Oak Tree",
				Models = sizes("Oak"),
				Drops = {
					{ Item = "OakBark", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "Acorn", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "OakResin", Chance = 0.08 }, -- Rare
				},
			},
			Birch = {
				Name = "Birch Tree",
				Models = sizes("Birch"),
				Drops = {
					{ Item = "BirchTwig", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "BirchLog", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "BirchSyrup", Chance = 0.08 }, -- Rare
				},
			},
			Apple = {
				Name = "Apple Tree",
				Models = sizes("Apple"),
				Drops = {
					{ Item = "AppleBranch", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "Apple", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "GoldenApple", Chance = 0.08 }, -- Rare
				},
			},
			Berry = {
				Name = "Berry Tree",
				Models = sizes("Berry"),
				Drops = {
					{ Item = "BerryTwig", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "Berry", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "StarBerry", Chance = 0.08 }, -- Rare
				},
			},
			Orange = {
				Name = "Orange Tree",
				Models = sizes("Orange"),
				Drops = {
					{ Item = "OrangePeel", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "Orange", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "SunOrange", Chance = 0.08 }, -- Rare
				},
			},
		},
		-- 20% of felled trees drop a hero. Shares: 40% / 40% / 15% / 4% / 1% of those,
		-- i.e. 8% / 8% / 3% / 0.8% / 0.2% per tree.
		HeroChance = 0.2,
		Heroes = GREEN_WOOD_HEROES,
	},

	[2] = {
		Name = "Orchard Valley",
		-- Only these three trees grow here (Oak / Birch do not).
		Trees = {
			Berry = {
				Name = "Berry Tree",
				Models = sizes("Berry"),
				Drops = {
					{ Item = "BerryLog", Chance = 1, Min = 2, Max = 4 }, -- Common
					{ Item = "BerryCluster", Chance = 0.35, Min = 1, Max = 2 }, -- Uncommon
					{ Item = "BerryJam", Chance = 0.08 }, -- Rare
				},
			},
			Orange = {
				Name = "Orange Tree",
				Models = sizes("Orange"),
				Drops = {
					{ Item = "OrangeSeed", Chance = 1, Min = 1, Max = 3 }, -- Uncommon
					{ Item = "OrchardOrange", Chance = 0.25, Min = 1, Max = 2 }, -- Rare
					{ Item = "OrangeJam", Chance = 0.04 }, -- Epic
				},
			},
			Apple = {
				Name = "Apple Tree",
				Models = sizes("Apple"),
				Drops = {
					{ Item = "OrchardApple", Chance = 1, Min = 1, Max = 2 }, -- Rare
					{ Item = "AppleJam", Chance = 0.12 }, -- Epic
					{ Item = "HeartOfTheOrchard", Chance = 0.005 }, -- Legendary (0.5%)
				},
			},
		},
		HeroChance = 0.2,
		Heroes = GREEN_WOOD_HEROES,
	},
} :: { [number]: ZoneDef }

function ZoneDrops.GetZone(zone: number?): ZoneDef
	return ZoneDrops.Zones[zone or 1] or ZoneDrops.Zones[1]
end

-- The tree definition (and size multiplier) for a model name in `zone`, or nil.
function ZoneDrops.GetTree(zone: number?, modelName: string?): (TreeDef?, number)
	if not modelName then
		return nil, 1
	end
	for _, tree in ZoneDrops.GetZone(zone).Trees do
		local mult = tree.Models[modelName]
		if mult then
			return tree, mult
		end
	end
	return nil, 1
end

-- Whether a tree model is allowed to grow in `zone`.
function ZoneDrops.GrowsIn(zone: number?, modelName: string): boolean
	return (ZoneDrops.GetTree(zone, modelName)) ~= nil
end

local scaledCache: { [TreeDef]: { [number]: { DropEntry } } } = {}

-- The drop list for a felled tree model in `zone` (already scaled by its size). Empty if the
-- model is not configured for that zone.
function ZoneDrops.GetDrops(zone: number?, modelName: string?): { DropEntry }
	local tree, mult = ZoneDrops.GetTree(zone, modelName)
	if not tree then
		return {}
	end
	local byMult = scaledCache[tree]
	if not byMult then
		byMult = {}
		scaledCache[tree] = byMult
	end
	local list = byMult[mult]
	if not list then
		list = {}
		for _, entry in tree.Drops do
			local min = entry.Min or 1
			local max = entry.Max or min
			table.insert(list, {
				Item = entry.Item,
				-- Guaranteed drops stay guaranteed; only their amount scales.
				Chance = if entry.Chance >= 1 then 1 else math.min(1, entry.Chance * mult),
				Min = math.max(1, math.floor(min * mult)),
				Max = math.max(1, math.floor(max * mult)),
			})
		end
		byMult[mult] = list
	end
	return list
end

-- Warns about items that are not defined in TreeConfig (typos etc.). Called once by the server.
function ZoneDrops.Validate()
	for zone, def in ZoneDrops.Zones do
		for _, hero in def.Heroes or {} do
			if not TreeConfig.GetHero(hero.Item) then
				warn(("[ZoneDrops] Zone %d Heroes: unknown hero %q (add it to HeroConfig)"):format(zone, hero.Item))
			end
		end
		for key, tree in def.Trees do
			for _, entry in tree.Drops do
				if not TreeConfig.Materials[entry.Item] and not TreeConfig.GetHero(entry.Item) then
					warn(("[ZoneDrops] Zone %d / %s: unknown item %q (add it to TreeConfig.Materials or HeroConfig)"):format(zone, key, entry.Item))
				end
			end
		end
	end
end

return ZoneDrops
