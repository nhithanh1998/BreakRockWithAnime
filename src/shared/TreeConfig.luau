--!strict
-- TreeConfig: everything about chopping trees and what they drop, shared by server and client.
--
-- Material definitions live here; heroes are in HeroConfig.luau. WHAT drops WHERE is in ZoneDrops.luau.

local HeroConfig = require(script.Parent:WaitForChild("HeroConfig"))

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

-- Drops render as square stud blocks (Minecraft-style cubes). "Gem" = block that also glows.
export type Visual = {
	Shape: "Block" | "Ball" | "Cylinder" | "Gem",
	Size: Vector3,
	Color: Color3,
	Material: Enum.Material,
}

export type MaterialDef = {
	Name: string,
	Rarity: Rarity,
	Value: number, -- money per item when sold
	Visual: Visual,
	Image: string?, -- optional UI icon (rbxassetid://...); without it the UI draws a 3D icon from Visual
}

export type DropEntry = {
	Item: string, -- key in Materials, or a hero Name from Heroes
	Chance: number, -- 0..1, rolled independently each time a tree is felled
	Min: number?, -- amount range (default 1..1)
	Max: number?,
}

export type HeroDef = HeroConfig.HeroDef

-- What the server sends to the client for each dropped stack.
export type Drop = {
	Kind: string,
	Name: string,
	Amount: number,
	Rarity: Rarity,
	Chance: number,
}

local TreeConfig = {}

-- Chopping ------------------------------------------------------------------------------------
TreeConfig.ClickDamage = 10 -- default; a player "ClickDamage" attribute overrides it (for upgrades)
TreeConfig.ClickCooldown = 0.12 -- seconds between hits (server allows a little slack)
TreeConfig.HoldToChop = true -- holding the mouse / finger keeps chopping
TreeConfig.MaxHitDistance = 120 -- studs from the character to the tree
TreeConfig.OnlyOwnPlot = true -- players can only chop trees on their own plot
TreeConfig.FellTime = 2.2 -- seconds the felled tree stays (fall + rest + fade) before removal
TreeConfig.FallDuration = 0.7 -- seconds from upright to hitting the floor
TreeConfig.LeafPartNames = { Leaf = true, Leaves = true }

-- Tree levels -----------------------------------------------------------------------------------
-- Every tree family grows in three levels: 1 = Sapling, 2 = Tree, 3 = Old tree (see ZoneDrops).
-- When a tree grows, a family is picked first (all families in the zone equally), then its level
-- by these weights. The plot owner's "TreeGrowth" attribute (skill tree upgrades) multiplies the
-- weight of level n by (1 + TreeGrowth * Boost[n]), so upgrades make big trees more common.
-- A template's "SpawnWeight" attribute (default 1) still multiplies its own weight.
TreeConfig.TreeLevels = {
	Weights = { 60, 30, 10 }, -- default: 60% sapling, 30% tree, 10% old tree
	Boost = { 0, 1, 2 },
	-- e.g. TreeGrowth 0.6 -> 60 / 48 / 22 = 46% / 37% / 17%
	--      TreeGrowth 1.6 -> 60 / 78 / 42 = 33% / 43% / 23%
}

-- Tree HP -------------------------------------------------------------------------------------
-- A tree's MaxHP comes from here (the "MaxHP" attribute on the templates is ignored), by the plot's
-- zone and the tree's level (1 Sapling / 2 Tree / 3 Old tree, see ZoneDrops). Values are plain
-- numbers or text tiers like HeroConfig.Power ("10K", "2.5M", "1.5T"; HeroConfig.ParseNumber).
-- A zone missing here uses the last zone listed, times ZoneMultiplier per zone past it.
--
-- Tuned so each zone's weakest hero (its first HeroConfig.Power value) needs about 8 / 30 / 60
-- swings at pad level 1, and its strongest one-shots saplings and trees:
--   zone 1  Power 5 .. 195           40 / 150 / 300        (5 dmg: 8 / 30 / 60 swings)
--   zone 2  Power 1.3K .. 307K       10K / 40K / 80K       (1.3K: 8 / 31 / 62)
--   zone 3  Power 325K .. 77.3M      2.5M / 10M / 20M      (325K: 8 / 31 / 62)
--   zone 4  Power 78.1M .. 48.8B     625M / 2.5B / 5B      (78.1M: 8 / 32 / 64)
--   zone 5  Power 49.5B .. 11.9T     400B / 1.5T / 3T      (49.5B: 8 / 30 / 61)
-- Player clicks (ShopConfig axe Damage 10 .. 650) are sized for zone 1 only.
TreeConfig.TreeHP = {
	Zones = {
		[1] = { 40, 150, 300 },
		[2] = { "10K", "40K", "80K" },
		[3] = { "2.5M", "10M", "20M" },
		[4] = { "625M", "2.5B", "5B" },
		[5] = { "400B", "1.5T", "3T" },
	} :: { [number]: { number | string } },
	ZoneMultiplier = 250, -- zones after the last one listed
}

-- MaxHP of a level 1..3 tree in `zone`.
function TreeConfig.MaxHP(zone: number?, level: number): number
	local cfg = TreeConfig.TreeHP
	local z = math.max(1, math.floor(zone or 1))
	local last = 1
	for listed in cfg.Zones do
		last = math.max(last, listed)
	end
	local row = cfg.Zones[math.min(z, last)] or cfg.Zones[1]
	local value = HeroConfig.ParseNumber(row[level] or row[#row] or 1) or 1
	if z > last then
		value *= cfg.ZoneMultiplier ^ (z - last)
	end
	return math.max(1, math.floor(value))
end

-- Effects -------------------------------------------------------------------------------------
TreeConfig.ShakeTime = 0.28
TreeConfig.ShakeAngle = 4 -- degrees
TreeConfig.LeavesPerHit = 6
TreeConfig.LeavesOnFell = 40
TreeConfig.HitFlashColor = Color3.fromRGB(255, 255, 255)
TreeConfig.HoverOutlineColor = Color3.fromRGB(255, 255, 255)

-- Target ring: spinning red dashed circle on the ground around a tree that is being chopped
-- (a hero is after it, or someone hit it in the last PlayerTargetTime seconds).
TreeConfig.TargetRing = {
	Color = Color3.fromRGB(255, 45, 45),
	Transparency = 0.05,
	SpinSpeed = 2.4, -- radians per second
	DashLength = 1.2, -- studs
	GapLength = 0.8, -- studs between dashes
	DashWidth = 0.4, -- studs (radial thickness)
	RadiusScale = 1, -- ring radius = half the dirt mound's widest side * this + Padding
	Padding = 0.6,
	MinRadius = 2,
	PlayerTargetTime = 1.2, -- seconds a hit keeps the ring on
	PopTime = 0.18, -- seconds for the ring to grow in / shrink out
}

-- Drops on the ground -------------------------------------------------------------------------
TreeConfig.DropHoldTime = 1.6 -- seconds drops sit on the ground before flying to the player
TreeConfig.DropSpread = { Min = 4, Max = 9 } -- studs from the tree

-- Chest (drops fly into the plot's TreasureChest) ---------------------------------------------
TreeConfig.ChestFlySpeed = 70 -- studs per second (flight time is clamped below)
TreeConfig.ChestFlyTime = { Min = 0.45, Max = 1.1 }
TreeConfig.ChestShakeAngle = 5 -- degrees
TreeConfig.ChestShakeTime = 0.22
TreeConfig.ChestFlashColor = Color3.fromRGB(255, 225, 90)

-- Chest UI ------------------------------------------------------------------------------------
TreeConfig.ChestPromptDistance = 12 -- studs; "E  Loot Chest / Open"
TreeConfig.ChestCloseDistance = 20 -- the chest window closes when you walk this far away
-- Slot backgrounds in the chest window, per rarity.
TreeConfig.RaritySlotColors = {
	Common = Color3.fromRGB(150, 150, 150),
	Uncommon = Color3.fromRGB(60, 170, 70),
	Rare = Color3.fromRGB(45, 110, 200),
	Epic = Color3.fromRGB(125, 55, 190),
	Legendary = Color3.fromRGB(215, 135, 30),
	Mythic = Color3.fromRGB(200, 40, 60),
} :: { [string]: Color3 }

TreeConfig.RarityOrder = { Mythic = 1, Legendary = 2, Epic = 3, Rare = 4, Uncommon = 5, Common = 6 } :: { [string]: number }

-- Heroes are configured in HeroConfig.luau; these are kept so existing callers keep working.
TreeConfig.Heroes = HeroConfig.Heroes
TreeConfig.GetHero = HeroConfig.Get

TreeConfig.RarityColors = {
	Common = Color3.fromRGB(230, 230, 230),
	Uncommon = Color3.fromRGB(110, 230, 110),
	Rare = Color3.fromRGB(80, 170, 255),
	Epic = Color3.fromRGB(190, 100, 255),
	Legendary = Color3.fromRGB(255, 200, 40),
	Mythic = Color3.fromRGB(255, 70, 90),
} :: { [string]: Color3 }

-- Rarities that get a burst effect when they drop.
TreeConfig.FancyRarities = { Rare = true, Epic = true, Legendary = true, Mythic = true } :: { [string]: boolean }

TreeConfig.Materials = {
	-- Zone 1 (Green Wood) - Oak Tree
	OakBark = {
		Name = "Oak Bark",
		Value = 5,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1.2, 1.2, 1.2), Color = Color3.fromRGB(96, 66, 44), Material = Enum.Material.Plastic },
	},
	Acorn = {
		Name = "Acorn",
		Value = 20,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(165, 112, 52), Material = Enum.Material.Plastic },
	},
	OakResin = {
		Name = "Oak Resin",
		Value = 120,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(235, 145, 35), Material = Enum.Material.Plastic },
	},
	-- Zone 1 (Green Wood) - Birch Tree
	BirchTwig = {
		Name = "Birch Twig",
		Value = 6,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(150, 118, 88), Material = Enum.Material.Plastic },
	},
	BirchLog = {
		Name = "Birch Log",
		Value = 25,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(1.2, 1.2, 1.2), Color = Color3.fromRGB(232, 226, 212), Material = Enum.Material.Plastic },
	},
	BirchSyrup = {
		Name = "Birch Syrup",
		Value = 150,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(200, 105, 40), Material = Enum.Material.Plastic },
	},
	-- Zone 1 (Green Wood) - Apple Tree
	AppleBranch = {
		Name = "Apple Branch",
		Value = 7,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(122, 88, 62), Material = Enum.Material.Plastic },
	},
	Apple = {
		Name = "Apple",
		Value = 30,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(215, 51, 43), Material = Enum.Material.Plastic },
	},
	GoldenApple = {
		Name = "Golden Apple",
		Value = 180,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(255, 200, 45), Material = Enum.Material.Plastic },
	},
	-- Zone 1 (Green Wood) - Berry Tree
	BerryTwig = {
		Name = "Berry Twig",
		Value = 8,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(110, 74, 60), Material = Enum.Material.Plastic },
	},
	Berry = {
		Name = "Berry",
		Value = 35,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(106, 63, 181), Material = Enum.Material.Plastic },
	},
	StarBerry = {
		Name = "Star Berry",
		Value = 210,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(150, 110, 255), Material = Enum.Material.Plastic },
	},
	-- Zone 1 (Green Wood) - Orange Tree
	OrangePeel = {
		Name = "Orange Peel",
		Value = 9,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(235, 150, 60), Material = Enum.Material.Plastic },
	},
	Orange = {
		Name = "Orange",
		Value = 40,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(242, 138, 28), Material = Enum.Material.Plastic },
	},
	SunOrange = {
		Name = "Sun Orange",
		Value = 250,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(255, 170, 30), Material = Enum.Material.Plastic },
	},
	-- Zone 2 (Orchard Valley) - Berry Tree
	-- Keys get an "Orchard" prefix where Zone 1 already uses the plain key ("Apple", "Orange").
	BerryLog = {
		Name = "Berry Log",
		Value = 15,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1.2, 1.2, 1.2), Color = Color3.fromRGB(105, 62, 70), Material = Enum.Material.Plastic },
	},
	BerryCluster = {
		Name = "Berry Cluster",
		Value = 60,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(125, 50, 170), Material = Enum.Material.Plastic },
	},
	BerryJam = {
		Name = "Berry Jam",
		Value = 350,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(170, 40, 120), Material = Enum.Material.Plastic },
	},
	-- Zone 2 (Orchard Valley) - Orange Tree
	OrangeSeed = {
		Name = "Orange Seed",
		Value = 70,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(0.8, 0.8, 0.8), Color = Color3.fromRGB(240, 215, 150), Material = Enum.Material.Plastic },
	},
	OrchardOrange = {
		Name = "Orange",
		Value = 400,
		Rarity = "Rare",
		Visual = { Shape = "Block", Size = Vector3.new(1.1, 1.1, 1.1), Color = Color3.fromRGB(250, 140, 20), Material = Enum.Material.Plastic },
	},
	OrangeJam = {
		Name = "Orange Jam",
		Value = 1500,
		Rarity = "Epic",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(255, 120, 10), Material = Enum.Material.Plastic },
	},
	-- Zone 2 (Orchard Valley) - Apple Tree
	OrchardApple = {
		Name = "Apple",
		Value = 450,
		Rarity = "Rare",
		Visual = { Shape = "Block", Size = Vector3.new(1.1, 1.1, 1.1), Color = Color3.fromRGB(220, 40, 45), Material = Enum.Material.Plastic },
	},
	AppleJam = {
		Name = "Apple Jam",
		Value = 1800,
		Rarity = "Epic",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(200, 25, 40), Material = Enum.Material.Plastic },
	},
	HeartOfTheOrchard = {
		Name = "Heart of the Orchard",
		Value = 8000,
		Rarity = "Legendary",
		Visual = { Shape = "Gem", Size = Vector3.new(1.1, 1.1, 1.1), Color = Color3.fromRGB(255, 205, 60), Material = Enum.Material.Plastic },
	},
	-- Old placeholder items (no longer dropped; kept so saved inventories can still be sold)
	Leaf = {
		Name = "Leaf",
		Value = 2,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1, 1, 1), Color = Color3.fromRGB(95, 170, 85), Material = Enum.Material.Plastic },
	},
	Fruit = {
		Name = "Fruit",
		Value = 12,
		Rarity = "Uncommon",
		Visual = { Shape = "Block", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(230, 60, 60), Material = Enum.Material.Plastic },
	},
	Amber = {
		Name = "Amber",
		Value = 150,
		Rarity = "Rare",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(255, 160, 30), Material = Enum.Material.Plastic },
	},
	Crystal = {
		Name = "Crystal",
		Value = 600,
		Rarity = "Epic",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(90, 220, 255), Material = Enum.Material.Plastic },
	},
} :: { [string]: MaterialDef }

return TreeConfig
