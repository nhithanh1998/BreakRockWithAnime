--!strict
-- ZoneDrops: which items can drop from trees in each zone.
--
-- A plot's zone is its "Zone" attribute (the same number that picks the tree models from
-- ReplicatedStorage.Trees.Map<Zone>).
--
-- Each drop entry:
--   Item   = a key in TreeConfig.Materials (e.g. "Honey") or a hero Name from HeroConfig.luau (e.g. "Uzumaki Kid")
--   Chance = 0..1, rolled on its own every time a tree is felled (0.25 = 25%)
--   Min/Max = how many drop when it hits (default 1)
--
-- Drops      = what every tree in the zone can drop.
-- Trees      = optional per-tree list (key = tree model name). When a tree has one, it is used
--              INSTEAD of Drops for that tree.
-- Zones without an entry fall back to zone 1.
--
-- Heroes (optional, per zone):
--   HeroChance = 0..1, chance that a felled tree drops ONE hero (any tree type). The player's
--                "HeroLuck" attribute multiplies it (default 1; for the skill tree / boosts).
--   Heroes     = which hero it is, picked by Weight (bigger = more common). The chance shown on a
--                dropped hero is HeroChance * luck * its weight share.
-- Heroes can also still be listed in Drops / Trees with their own Chance (rolled on their own).
--
-- New item? Add it to TreeConfig.Materials (or HeroConfig.Heroes) first, then list it here.

local TreeConfig = require(script.Parent:WaitForChild("TreeConfig"))

type DropEntry = TreeConfig.DropEntry

export type HeroEntry = {
	Item: string, -- hero Name from HeroConfig
	Weight: number,
}

export type ZoneDef = {
	Name: string,
	Drops: { DropEntry },
	Trees: { [string]: { DropEntry } }?,
	HeroChance: number?,
	Heroes: { HeroEntry }?,
}

local ZoneDrops = {}

-- Zone 1 (Green Wood) helpers ------------------------------------------------------------------

-- Builds a tree's material drops, scaled by `amount` (sapling < normal < old).
local function greenWoodTree(common: string, uncommon: string, rare: string, amount: number): { DropEntry }
	return {
		{ Item = common, Chance = 1, Min = math.max(1, math.floor(2 * amount)), Max = math.max(1, math.floor(4 * amount)) },
		{ Item = uncommon, Chance = math.min(1, 0.35 * amount), Min = 1, Max = math.max(1, math.floor(2 * amount)) },
		{ Item = rare, Chance = math.min(1, 0.08 * amount), Min = 1, Max = 1 },
	}
end

local function oak(amount: number)
	return greenWoodTree("OakBark", "Acorn", "OakResin", amount)
end

local function birch(amount: number)
	return greenWoodTree("BirchTwig", "BirchLog", "BirchSyrup", amount)
end

ZoneDrops.Zones = {
	[1] = {
		Name = "Green Wood",
		Drops = oak(1), -- fallback for any tree not listed below
		Trees = {
			-- Oak Tree: Oak Bark (Common), Acorn (Uncommon), Oak Resin (Rare)
			OakSapling = oak(0.5),
			OakTree = oak(1),
			OldOakTree = oak(1.5),
			-- Birch Tree: Birch Twig (Common), Birch Log (Uncommon), Birch Syrup (Rare)
			BirchSapling = birch(0.5),
			BirchTree = birch(1),
			OldBirchTree = birch(1.5),
		},
		-- 20% of felled trees drop a hero. Shares: 40% / 40% / 15% / 4% / 1% of those,
		-- i.e. 8% / 8% / 3% / 0.8% / 0.2% per tree.
		HeroChance = 0.2,
		Heroes = {
			{ Item = "Sling Pirate", Weight = 40 }, -- Common
			{ Item = "Taijutsu Ninja", Weight = 40 }, -- Common
			{ Item = "Uzumaki Kid", Weight = 15 }, -- Uncommon
			{ Item = "Copy Ninja", Weight = 4 }, -- Rare
			{ Item = "Perfect Bioform", Weight = 1 }, -- Epic
		},
	},

	-- Example for the next zone; edit freely.
	[2] = {
		Name = "Fruit Grove",
		Drops = {
			{ Item = "Leaf", Chance = 0.8, Min = 2, Max = 5 },
			{ Item = "Fruit", Chance = 0.6, Min = 1, Max = 3 },
			{ Item = "Amber", Chance = 0.12 },
			{ Item = "Crystal", Chance = 0.05 },
			{ Item = "Copy Ninja", Chance = 0.03 },
			{ Item = "Flame Pillar", Chance = 0.01 },
		},
	},
} :: { [number]: ZoneDef }

function ZoneDrops.GetZone(zone: number?): ZoneDef
	return ZoneDrops.Zones[zone or 1] or ZoneDrops.Zones[1]
end

-- The drop list for a tree of `treeType` in `zone`.
function ZoneDrops.GetDrops(zone: number?, treeType: string?): { DropEntry }
	local def = ZoneDrops.GetZone(zone)
	local perTree = def.Trees and treeType and def.Trees[treeType]
	return perTree or def.Drops
end

-- Warns about items that are not defined in TreeConfig (typos etc.). Called once by the server.
function ZoneDrops.Validate()
	local function check(where: string, list: { DropEntry })
		for _, entry in list do
			if not TreeConfig.Materials[entry.Item] and not TreeConfig.GetHero(entry.Item) then
				warn(("[ZoneDrops] %s: unknown item %q (add it to TreeConfig.Materials or HeroConfig)"):format(where, entry.Item))
			end
		end
	end
	for zone, def in ZoneDrops.Zones do
		check(("Zone %d"):format(zone), def.Drops)
		for _, hero in def.Heroes or {} do
			if not TreeConfig.GetHero(hero.Item) then
				warn(("[ZoneDrops] Zone %d Heroes: unknown hero %q (add it to HeroConfig)"):format(zone, hero.Item))
			end
		end
		if def.Trees then
			for tree, list in def.Trees do
				check(("Zone %d / %s"):format(zone, tree), list)
			end
		end
	end
end

return ZoneDrops
