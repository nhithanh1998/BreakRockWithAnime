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
TreeConfig.FellTime = 0.9 -- seconds the felled tree stays (for the fall animation) before removal
TreeConfig.LeafPartNames = { Leaf = true, Leaves = true }

-- Effects -------------------------------------------------------------------------------------
TreeConfig.ShakeTime = 0.28
TreeConfig.ShakeAngle = 4 -- degrees
TreeConfig.LeavesPerHit = 6
TreeConfig.LeavesOnFell = 40
TreeConfig.HitFlashColor = Color3.fromRGB(255, 255, 255)
TreeConfig.HoverOutlineColor = Color3.fromRGB(255, 255, 255)

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
	-- Zone 1
	OakWood = {
		Name = "Oak Wood",
		Value = 5,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(1.2, 1.2, 1.2), Color = Color3.fromRGB(124, 92, 70), Material = Enum.Material.Plastic },
	},
	OakSapling = {
		Name = "Oak Sapling",
		Value = 8,
		Rarity = "Common",
		Visual = { Shape = "Block", Size = Vector3.new(0.8, 0.8, 0.8), Color = Color3.fromRGB(110, 190, 80), Material = Enum.Material.Plastic },
	},
	Honey = {
		Name = "Honey",
		Value = 20,
		Rarity = "Uncommon",
		Visual = { Shape = "Gem", Size = Vector3.new(0.9, 0.9, 0.9), Color = Color3.fromRGB(255, 185, 30), Material = Enum.Material.Plastic },
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
