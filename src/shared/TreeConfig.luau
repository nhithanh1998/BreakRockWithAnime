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
	SpinSpeed = 0.9, -- radians per second
	DashLength = 2.4, -- studs
	GapLength = 1.5, -- studs between dashes
	DashWidth = 0.85, -- studs (radial thickness)
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
	-- Zone 2
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
