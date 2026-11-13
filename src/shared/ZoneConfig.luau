--!strict
-- ZoneConfig: the zones a player can unlock and travel to from the Zones board on their plot
-- (plot.ZoneBoard.Board, drawn by ZoneBoardUI, handled by ZoneBoardService).
--
-- Zones are unlocked in order: only the next one (UnlockedZones + 1) can be bought, for its Price.
-- Unlocked zones can be swapped to for free at any time.
-- What grows / drops in each zone is in ZoneDrops.luau; the map layout is ServerStorage.ZoneLayouts.ZoneN.
--
-- Base = the zone's stats BEFORE any skill tree upgrade. The zone's skill tree (SkillTreeConfig,
-- tree with Zone = n) adds on top of these; keys missing from a zone use ZoneConfig.DefaultBase.
--   MaxTrees         trees standing on the plot at once            (skills: Seedling, Thick Forest)
--   RespawnTime      seconds before a felled tree grows back
--   TreeLevelWeights how often a new tree is Sapling / Tree / Old tree (relative weights)
--   OldTreeChance    chance a new tree grows one level older       (skills: Elder Grove)
--   ChopYield        extra main wood on every felled tree           (skills: Extra Bark, Lumber Haul)
--   Luck             multiplier on rare material + anime chances    (skills: Lucky / Golden Acorn, Hardwood, Ironwood)
--   HeroChance       chance a felled tree drops an anime            (skills: Hero Sprout)
--   DropValue        sell price multiplier of this zone's materials (skills: Hardwood / Ironwood, highest wins)
--   TreeHP           multiplier on tree HP (TreeConfig.TreeHP)     (skills: Hardwood / Ironwood, highest wins)
--   HPCut            share of tree HP removed (0.15 = -15%)        (skills: Termites, Woodpecker, Rotten Core)
-- Tree HP numbers themselves (per level) are in TreeConfig.TreeHP; drops in ZoneDrops.

export type ZoneBase = {
	MaxTrees: number?,
	RespawnTime: number?,
	TreeLevelWeights: { number }?,
	OldTreeChance: number?,
	ChopYield: number?,
	Luck: number?,
	HeroChance: number?,
	DropValue: number?,
	TreeHP: number?,
	HPCut: number?,
}

export type ZoneInfo = {
	Name: string,
	Price: number, -- Money to unlock (zone 1 is always unlocked)
	Color: Color3, -- row accent colour on the board
	Base: ZoneBase?,
}

local ZoneConfig = {}

-- Used for any Base key a zone leaves out.
ZoneConfig.DefaultBase = {
	MaxTrees = 12,
	RespawnTime = 4,
	TreeLevelWeights = { 60, 30, 10 }, -- 60% Sapling, 30% Tree, 10% Old tree
	OldTreeChance = 0,
	ChopYield = 0,
	Luck = 1,
	HeroChance = 0.2,
	DropValue = 1,
	TreeHP = 1,
	HPCut = 0,
} :: ZoneBase

ZoneConfig.Zones = {
	[1] = {
		Name = "Green Wood",
		Price = 0,
		Color = Color3.fromRGB(80, 190, 70),
		Base = {
			MaxTrees = 12,
			RespawnTime = 4,
			TreeLevelWeights = { 60, 30, 10 },
			OldTreeChance = 0,
			ChopYield = 0,
			Luck = 1,
			HeroChance = 0.2, -- 20% of felled trees drop an anime
			DropValue = 1,
			TreeHP = 1,
			HPCut = 0,
		},
	},
	-- Price: ~15-20 min of zone 1 with a few upgraded heroes.
	[2] = {
		Name = "Orchard Valley",
		Price = 25000,
		Color = Color3.fromRGB(235, 120, 40),
		Base = {
			MaxTrees = 12,
			RespawnTime = 4,
			TreeLevelWeights = { 60, 30, 10 },
			OldTreeChance = 0,
			ChopYield = 0,
			Luck = 1,
			HeroChance = 0.2,
			DropValue = 1,
			TreeHP = 1,
			HPCut = 0,
		},
	},
} :: { [number]: ZoneInfo }

-- Shown as a greyed-out row under the last zone; set to nil to hide it.
ZoneConfig.ComingSoonText = "More Zones Soon!"

function ZoneConfig.Count(): number
	return #ZoneConfig.Zones
end

function ZoneConfig.Get(zone: number): ZoneInfo?
	return ZoneConfig.Zones[zone]
end

-- One base value of `zone` (falls back to DefaultBase).
function ZoneConfig.GetBase(zone: number?, key: string): any
	local info = ZoneConfig.Zones[zone or 1]
	local base = info and info.Base :: any
	local value = base and base[key]
	if value == nil then
		value = (ZoneConfig.DefaultBase :: any)[key]
	end
	return value
end

return ZoneConfig
