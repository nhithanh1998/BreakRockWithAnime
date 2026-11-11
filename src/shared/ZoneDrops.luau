--!strict
-- ZoneDrops: which items can drop from trees in each zone.
--
-- A plot's zone is its "Zone" attribute (the same number that picks the tree models from
-- ReplicatedStorage.Tress.Map<Zone>).
--
-- Each drop entry:
--   Item   = a key in TreeConfig.Materials (e.g. "Honey") or a hero Name from HeroConfig.luau (e.g. "Naruto")
--   Chance = 0..1, rolled on its own every time a tree is felled (0.25 = 25%)
--   Min/Max = how many drop when it hits (default 1)
--
-- Drops      = what every tree in the zone can drop.
-- Trees      = optional per-tree list (key = tree model name). When a tree has one, it is used
--              INSTEAD of Drops for that tree.
-- Zones without an entry fall back to zone 1.
--
-- New item? Add it to TreeConfig.Materials (or HeroConfig.Heroes) first, then list it here.

local TreeConfig = require(script.Parent:WaitForChild("TreeConfig"))

type DropEntry = TreeConfig.DropEntry

export type ZoneDef = {
	Name: string,
	Drops: { DropEntry },
	Trees: { [string]: { DropEntry } }?,
}

local ZoneDrops = {}

ZoneDrops.Zones = {
	[1] = {
		Name = "Oak Forest",
		Drops = {
			{ Item = "OakWood", Chance = 1, Min = 2, Max = 4 },
			{ Item = "OakSapling", Chance = 0.5, Min = 1, Max = 2 },
			{ Item = "Honey", Chance = 0.25, Min = 1, Max = 2 },
			{ Item = "Naruto", Chance = 0.03 },
		},
		Trees = {
			-- Small trees drop less.
			OakSapling = {
				{ Item = "OakWood", Chance = 1, Min = 1, Max = 2 },
				{ Item = "OakSapling", Chance = 0.4, Min = 1, Max = 1 },
				{ Item = "Honey", Chance = 0.1, Min = 1, Max = 1 },
				{ Item = "Naruto", Chance = 0.01 },
			},
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
			{ Item = "Leaf Ninja", Chance = 0.03 },
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
		if def.Trees then
			for tree, list in def.Trees do
				check(("Zone %d / %s"):format(zone, tree), list)
			end
		end
	end
end

return ZoneDrops
